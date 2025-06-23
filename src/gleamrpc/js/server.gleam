import convert
import gleam/dynamic/decode
import gleam/function
import gleam/javascript/promise
import gleam/result
import gleamrpc

/// The types of errors handled by a Procedure Server
pub type ServerError(error) {
  /// This error means that the procedure was not found on the server
  WrongProcedure
  /// This error means an error happened during the execution of the procedure
  ProcedureExecError(error: error)
  /// This error means that something went wrong while parsing the parameters of the procedure
  GetParamsError(error: error)
  /// This error means that something went wrong while decoding the parameters of the procedure
  ParamsDecodeError(errors: List(decode.DecodeError))
  /// This error means that something went wrong while retrieving the procedure identity
  GetIdentityError(error: error)
}

/// The Server Definition is 
pub type ProcedureServerDefinition(transport_in, transport_out, error) {
  ProcedureServerDefinition(
    get_identity: fn(transport_in) -> Result(gleamrpc.ProcedureIdentity, error),
    get_params: fn(transport_in, gleamrpc.ProcedureType, convert.GlitrType) ->
      Result(convert.GlitrValue, error),
    recover_error: fn(ServerError(error)) -> transport_out,
    encode_result: fn(convert.GlitrValue) -> transport_out,
  )
}

type ExecFn(context, error) =
  fn(convert.GlitrValue, context) ->
    promise.Promise(Result(convert.GlitrValue, ServerError(error)))

type GetParamsFn(transport_in, error) =
  fn(transport_in) -> Result(convert.GlitrValue, error)

type ProcedureRegistration(transport_in, context, error) {
  ProcedureRegistration(
    identity: gleamrpc.ProcedureIdentity,
    get_params: GetParamsFn(transport_in, error),
    exec: ExecFn(context, error),
  )
}

pub type ProcedureServerMiddleware(transport_in, transport_out) =
  fn(transport_in, fn(transport_in) -> promise.Promise(transport_out)) ->
    promise.Promise(transport_out)

/// A ProcedureServerInstance combines a procedure server and handler.  
/// It also manages context creation and procedure registration.
pub opaque type ProcedureServer(transport_in, transport_out, context, error) {
  ProcedureServer(
    definition: ProcedureServerDefinition(transport_in, transport_out, error),
    context_factory: fn(transport_in) -> context,
    middlewares: List(ProcedureServerMiddleware(transport_in, transport_out)),
    implementations: List(ProcedureRegistration(transport_in, context, error)),
  )
}

pub fn simple(
  definition: ProcedureServerDefinition(transport_in, transport_out, error),
) -> ProcedureServer(transport_in, transport_out, transport_in, error) {
  ProcedureServer(
    definition:,
    context_factory: function.identity,
    middlewares: [],
    implementations: [],
  )
}

pub fn advanced(
  definition: ProcedureServerDefinition(transport_in, transport_out, error),
  context_factory: fn(transport_in) -> context,
) -> ProcedureServer(transport_in, transport_out, context, error) {
  ProcedureServer(
    definition:,
    context_factory:,
    middlewares: [],
    implementations: [],
  )
}

pub fn with_middleware(
  server: ProcedureServer(in, out, ctx, err),
  middleware: ProcedureServerMiddleware(in, out),
) -> ProcedureServer(in, out, ctx, err) {
  ProcedureServer(..server, middlewares: [middleware, ..server.middlewares])
}

pub fn with_implementation(
  server: ProcedureServer(in, out, ctx, err),
  procedure: gleamrpc.Procedure(params, return),
  implementation: fn(params, ctx) -> promise.Promise(Result(return, err)),
) -> ProcedureServer(in, out, ctx, err) {
  ProcedureServer(..server, implementations: [
    ProcedureRegistration(
      identity: gleamrpc.ProcedureIdentity(
        procedure.name,
        procedure.router,
        procedure.type_,
      ),
      exec: procedure_fn(procedure, implementation),
      get_params: fn(in: in) {
        server.definition.get_params(
          in,
          procedure.type_,
          procedure.params_type |> convert.type_def(),
        )
      },
    ),
    ..server.implementations
  ])
}

/// Convert a server instance to a simple function 
/// 
/// Example : 
/// 
/// ```gleam
/// gleamrpc.with_server(http_server())
/// |> gleamrpc.with_implementation(my_procedure, implementation)
/// |> gleamrpc.serve
/// |> mist.new
/// |> mist.start_http
/// ```
pub fn serve(
  server: ProcedureServer(transport_in, transport_out, context, error),
) -> fn(transport_in) -> promise.Promise(transport_out) {
  fn(in: transport_in) {
    use in <- execute_middlewares(in, server.middlewares)
    let context = server.context_factory(in)
    let identity_result = server.definition.get_identity(in)

    case identity_result {
      Error(err) ->
        GetIdentityError(err)
        |> server.definition.recover_error()
        |> promise.resolve()
      Ok(identity) -> {
        execute_procedures(server.implementations, in, identity, context)
        |> promise.map(fn(result_data) {
          case result_data {
            Ok(data) -> server.definition.encode_result(data)
            Error(err) -> server.definition.recover_error(err)
          }
        })
      }
    }
  }
}

fn execute_middlewares(
  in: transport_in,
  middlewares: List(ProcedureServerMiddleware(transport_in, transport_out)),
  next: fn(transport_in) -> promise.Promise(transport_out),
) -> promise.Promise(transport_out) {
  case middlewares {
    [] -> next(in)
    [middleware, ..rest] -> {
      use new_in <- middleware(in)
      execute_middlewares(new_in, rest, next)
    }
  }
}

fn execute_procedures(
  procedures: List(ProcedureRegistration(transport_in, context, error)),
  data_in: transport_in,
  identity: gleamrpc.ProcedureIdentity,
  context: context,
) -> promise.Promise(Result(convert.GlitrValue, ServerError(error))) {
  case procedures {
    [proc, ..] if proc.identity == identity -> {
      proc.get_params(data_in)
      |> result.map(proc.exec(_, context))
      |> result.map_error(fn(err) {
        Error(GetParamsError(err)) |> promise.resolve()
      })
      |> result.unwrap_both()
    }
    [_, ..rest] -> execute_procedures(rest, data_in, identity, context)
    [] -> promise.resolve(Error(WrongProcedure))
  }
}

fn procedure_fn(
  procedure: gleamrpc.Procedure(params, return),
  implementation: fn(params, context) -> promise.Promise(Result(return, error)),
) -> ExecFn(context, error) {
  fn(params_value: convert.GlitrValue, ctx: context) {
    let params =
      params_value
      |> convert.decode(procedure.params_type)
      |> result.map_error(ParamsDecodeError)

    case params {
      Ok(params) ->
        implementation(params, ctx)
        |> promise.map(fn(data_out) {
          data_out
          |> result.map(convert.encode(procedure.return_type))
          |> result.map_error(ProcedureExecError)
        })
      Error(err) -> promise.resolve(Error(err))
    }
  }
}

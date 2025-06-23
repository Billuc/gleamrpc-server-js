import convert
import convert/json as cjson
import gleam/bool
import gleam/float
import gleam/int
import gleam/io
import gleam/javascript/promise
import gleam/json
import gleam/option
import gleam/result
import gleamrpc
import gleamrpc/js/server
import gleeunit

fn get_identity(
  data: #(String, String),
) -> Result(gleamrpc.ProcedureIdentity, String) {
  gleamrpc.ProcedureIdentity(
    name: data.0,
    router: option.None,
    type_: gleamrpc.Query,
  )
  |> Ok
}

fn get_params(
  data: #(String, String),
  _proctype: gleamrpc.ProcedureType,
  paramstype: convert.GlitrType,
) -> Result(convert.GlitrValue, String) {
  data.1
  |> json.parse(cjson.decoder(paramstype))
  |> result.replace_error("Couldn't decode !")
}

fn recover_error(error: server.ServerError(String)) -> String {
  case error {
    server.GetIdentityError(error:) -> error
    server.GetParamsError(error:) -> error
    server.ParamsDecodeError(_errors) -> "Decoding errors"
    server.ProcedureExecError(error:) -> error
    server.WrongProcedure -> "Procedure not found"
  }
}

fn encode_result(result: convert.GlitrValue) -> String {
  case result {
    convert.BoolValue(value:) -> bool.to_string(value)
    convert.FloatValue(value:) -> float.to_string(value)
    convert.IntValue(value:) -> int.to_string(value)
    convert.StringValue(value:) -> value
    _ -> "Unsupported"
  }
}

fn mock_str_procedure() {
  gleamrpc.query("string", option.None)
  |> gleamrpc.params(convert.string())
  |> gleamrpc.returns(convert.string())
}

fn mock_int_procedure() {
  gleamrpc.query("int", option.None)
  |> gleamrpc.params(convert.int())
  |> gleamrpc.returns(convert.int())
}

fn mock_str_implementation(
  in: String,
  _: ctx,
) -> promise.Promise(Result(String, String)) {
  { "Hello, " <> in }
  |> Ok
  |> promise.resolve
}

fn mock_int_implementation(
  in: Int,
  _: ctx,
) -> promise.Promise(Result(Int, String)) {
  { 2 * in }
  |> Ok
  |> promise.resolve()
}

pub fn mock_server() {
  let serverdef =
    server.ProcedureServerDefinition(
      get_identity:,
      get_params:,
      recover_error:,
      encode_result:,
    )

  server.simple(serverdef)
  |> server.with_middleware(
    fn(
      in: #(String, String),
      next: fn(#(String, String)) -> promise.Promise(String),
    ) {
      io.println("Procedure " <> in.0 <> " with arg " <> in.1)
      next(in)
    },
  )
  |> server.with_implementation(mock_str_procedure(), mock_str_implementation)
  |> server.with_implementation(mock_int_procedure(), mock_int_implementation)
}

pub fn server_str_procedure_test() {
  #("string", "\"world\"")
  |> server.serve(mock_server())
  |> promise.tap(fn(res) {
    assert res == "Hello, world"
  })
}

pub fn server_int_procedure_test() {
  #("int", "3")
  |> server.serve(mock_server())
  |> promise.tap(fn(res) {
    assert res == "6"
  })
}

pub fn main() -> Nil {
  gleeunit.main()
}

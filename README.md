# gleamrpc_js_server

[![Package Version](https://img.shields.io/hexpm/v/gleamrpc_js_server)](https://hex.pm/packages/gleamrpc_js_server)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/gleamrpc_js_server/)

This library is used to create servers for GleamRPC on Javascript targets.

Usually, you only want to use this library if you wish to create your own GleamRPC server implementation.  
See [gleamrpc_http_server]() for the HTTP server implementation.

```sh
gleam add gleamrpc gleamrpc_js_server
```
```gleam
import convert
import gleamrpc/js/server
import gleamrpc

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
    convert.StringValue(value:) -> value
    _ -> "Unsupported"
  }
}

fn mock_str_procedure() {
  gleamrpc.query("string", option.None)
  |> gleamrpc.params(convert.string())
  |> gleamrpc.returns(convert.string())
}

fn mock_str_implementation(
  in: String,
  _: ctx,
) -> promise.Promise(Result(String, String)) {
  { "Hello, " <> in }
  |> Ok
  |> promise.resolve
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
}

pub fn main() -> Nil {
  #("string", "\"world\"")
  |> server.serve(mock_server())
  |> promise.tap(fn(res) {
    assert res == "Hello, world"
  })
}
```

Further documentation can be found at <https://hexdocs.pm/gleamrpc_js_server>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

import gleam/bit_string
import gleam/string_builder.{StringBuilder}
import gleam/bit_string
import gleam/erlang/atom.{Atom}
import gleam/erlang/charlist.{Charlist}
import gleam/http
import gleam/http/request.{Request}
import gleam/http/response.{Response}
import gleam/int
import gleam/list
import gleam/option.{Option}
import gleam/otp/actor
import gleam/otp/process
import gleam/result
import gleam/string
import gleam_tcp/tcp.{HandlerMessage, Socket, send}

pub type PacketType {
  Http
  HttphBin
}

pub type HttpUri {
  AbsPath(Charlist)
}

pub type HttpPacket {
  HttpRequest(Atom, HttpUri, #(Int, Int))
  HttpHeader(Int, Atom, BitString, BitString)
}

pub type DecodedPacket {
  BinaryData(HttpPacket, BitString)
  EndOfHeaders(BitString)
  MoreData(Option(Int))
}

pub type DecodeError {
  InvalidMethod
  UnknownHeader
}

external fn decode_packet(
  packet_type: PacketType,
  packet: BitString,
  options: List(a),
) -> Result(DecodedPacket, DecodeError) =
  "gleam_tcp_ffi" "decode_packet"

pub fn from_header(value: BitString) -> String {
  assert Ok(value) = bit_string.to_string(value)

  string.lowercase(value)
}

pub fn parse_headers(
  bs: BitString,
  headers: List(http.Header),
) -> Result(#(List(http.Header), BitString), DecodeError) {
  case decode_packet(HttphBin, bs, []) {
    Ok(BinaryData(HttpHeader(_, _field, field, value), rest)) -> {
      let field = from_header(field)
      let value = from_header(value)
      parse_headers(rest, [#(field, value), ..headers])
    }
    Ok(EndOfHeaders(rest)) -> Ok(#(headers, rest))
    _ -> Error(UnknownHeader)
  }
}

pub fn parse_request(bs: BitString) -> Result(Request(BitString), DecodeError) {
  try BinaryData(req, rest) = decode_packet(Http, bs, [])
  assert HttpRequest(method, AbsPath(path), _version) = req

  try method =
    method
    |> atom.to_string
    |> http.parse_method
    |> result.replace_error(InvalidMethod)

  try #(headers, _rest) = parse_headers(rest, [])

  let req =
    request.new()
    |> request.set_body(<<>>)
    |> request.set_method(method)
    |> request.set_path(charlist.to_string(path))

  Ok(Request(..req, headers: headers))
}

pub fn code_to_string(code: Int) -> String {
  case code {
    200 -> "Ok"
    _ -> "Unknown"
  }
}

pub fn headers(resp: Response(BitString)) -> StringBuilder {
  list.fold(
    resp.headers,
    string_builder.from_string(""),
    fn(builder, tup) {
      let #(header, value) = tup

      string_builder.from_strings([header, ": ", value, "\r\n"])
      |> string_builder.append_builder(builder, _)
    },
  )
}

pub fn to_string(resp: Response(BitString)) -> BitString {
  let body_builder = case bit_string.byte_size(resp.body) {
    0 -> string_builder.from_string("")
    _size ->
      resp.body
      |> bit_string.to_string
      |> result.unwrap("")
      |> string_builder.from_string
      |> string_builder.append("\r\n")
  }

  "HTTP/1.1 "
  |> string_builder.from_string
  |> string_builder.append(int.to_string(resp.status))
  |> string_builder.append("\r\n")
  |> string_builder.append_builder(headers(resp))
  |> string_builder.append("\r\n\r\n")
  |> string_builder.append_builder(body_builder)
  |> string_builder.to_string
  |> bit_string.from_string
}

pub fn http_response(status: Int, body: BitString) -> BitString {
  response.new(status)
  |> response.set_body(body)
  |> response.prepend_header("Content-Type", "text/plain")
  |> response.prepend_header(
    "Content-Length",
    body
    |> bit_string.byte_size
    |> fn(size) { size + 1 }
    |> int.to_string,
  )
  |> response.prepend_header("Connection", "close")
  |> to_string
}

pub fn ok(_msg: HandlerMessage, sock: Socket) -> actor.Next(Socket) {
  "hello, world!"
  |> bit_string.from_string
  |> http_response(200, _)
  |> send(sock, _)

  actor.Stop(process.Normal)
}
// pub fn echo(msg: HandlerMessage, sock: Socket) -> actor.Next(Socket) {
//   case msg {
//     ReceiveMessage()
//   }
// }

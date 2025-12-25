import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/response
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string_tree
import mist
import simplifile

type PubSubMessage {
  Subscribe(client: Subject(String))
  Unsubscribe(client: Subject(String))
  Publish(String)
}

fn handle_pubsub_message(clients: List(Subject(String)), message: PubSubMessage) {
  case message {
    Subscribe(client) -> {
      io.println("➕ Client connected")
      actor.continue([client, ..clients])
    }
    Unsubscribe(client) -> {
      io.println("➖ Client disconnected")
      clients
      |> list.filter(fn(c) { c != client })
      |> actor.continue
    }
    Publish(message) -> {
      io.println("💬 " <> message)
      list.each(clients, fn(client) { process.send(client, message) })
      actor.continue(clients)
    }
  }
}

fn new_response(status: Int, body: String) {
  response.new(status)
  |> response.set_body(body |> bytes_tree.from_string |> mist.Bytes)
}

pub fn main() {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(handle_pubsub_message)
    |> actor.start()

  let pubsub = started.data

  let assert Ok(_) =
    mist.new(fn(request) {
      case request.method, request.path {
        http.Get, "/" -> {
          let body = case simplifile.read("src/index.html") {
            Ok(content) -> content
            Error(_) -> "Welcome to the Chat! (index.html not found)"
          }
          new_response(200, body) |> Ok
        }

        http.Post, "/post" -> {
          use request <- result.try(
            mist.read_body(request, 128)
            |> result.replace_error("Could not read request body."),
          )
          use message <- result.try(
            bit_array.to_string(request.body)
            |> result.replace_error("Could not convert request body to string."),
          )

          actor.send(pubsub, Publish(message))
          new_response(200, "Submitted") |> Ok
        }

        http.Get, "/sse" -> {
          mist.server_sent_events(
            request,
            response.new(200),
            init: fn(_conn) {
              let client = process.new_subject()
              actor.send(pubsub, Subscribe(client))

              let selector =
                process.new_selector()
                |> process.select(client)

              actor.initialised(client)
              |> actor.selecting(selector)
              |> Ok
            },
            loop: fn(client, message, connection) {
              let event = message |> string_tree.from_string |> mist.event
              case mist.send_event(connection, event) {
                Ok(_) -> actor.continue(client)
                Error(_) -> {
                  actor.send(pubsub, Unsubscribe(client))
                  actor.stop()
                }
              }
            },
          )
          |> Ok
        }

        _, _ -> Ok(new_response(404, "Not found"))
      }
      |> result.unwrap(new_response(500, "Internal Server Error"))
    })
    |> mist.port(3000)
    |> mist.start

  process.sleep_forever()
}

defmodule Mint.HTTP1 do
  @moduledoc """
  Processless HTTP client with support for HTTP/1 and HTTP/1.1.

  This module provides a data structure that represents an HTTP/1 or HTTP/1.1 connection to
  a given server. The connection is represented as an opaque struct `%Mint.HTTP1{}`.
  The connection is a data structure and is not backed by a process, and all the
  connection handling happens in the process that creates the struct.

  This module and data structure work exactly like the ones described in the `Mint`
  module, with the exception that `Mint.HTTP1` specifically deals with HTTP/1 and HTTP/1.1 while
  `Mint` deals seamlessly with HTTP/1, HTTP/1.1, and HTTP/2. For more information on
  how to use the data structure and client architecture, see `Mint`.
  """

  import Mint.Core.Util

  alias Mint.Core.Util
  alias Mint.HTTP1.{Parse, Request, Response}
  alias Mint.{HTTPError, TransportError, Types}

  require Logger

  @behaviour Mint.Core.Conn

  @opaque t() :: %__MODULE__{}

  @user_agent "mint/" <> Mix.Project.config()[:version]

  @typedoc """
  An HTTP/1-specific error reason.

  The values can be:

    * `:closed` - when you try to make a request or stream a body chunk but the connection
      is closed.

    * `:request_body_is_streaming` - when you call `request/5` to send a new
      request but another request is already streaming.

    * `{:unexpected_data, data}` - when unexpected data is received from the server.

    * `:invalid_status_line` - when the HTTP/1 status line is invalid.

    * `{:invalid_request_target, target}` - when the request target is invalid.

    * `:invalid_header` - when headers can't be parsed correctly.

    * `{:invalid_header_name, name}` - when a header name is invalid.

    * `{:invalid_header_value, name, value}` - when a header value is invalid. `name`
      is the name of the header and `value` is the invalid value.

    * `:invalid_chunk_size` - when the chunk size is invalid.

    * `:missing_crlf_after_chunk` - when the CRLF after a chunk is missing.

    * `:invalid_trailer_header` - when trailer headers can't be parsed.

    * `:more_than_one_content_length_header` - when more than one `content-length`
      headers are in the response.

    * `:transfer_encoding_and_content_length` - when both the `content-length` as well
      as the `transfer-encoding` headers are in the response.

    * `{:invalid_content_length_header, value}` - when the value of the `content-length`
      header is invalid, that is, is not an non-negative integer.

    * `:empty_token_list` - when a header that is supposed to contain a list of tokens
      (such as the `connection` header) doesn't contain any.

    * `{:invalid_token_list, string}` - when a header that is supposed to contain a list
      of tokens (such as the `connection` header) contains a malformed list of tokens.

  """
  @type error_reason() :: term()

  defstruct [
    :host,
    :request,
    :socket,
    :transport,
    :mode,
    requests: :queue.new(),
    state: :closed,
    buffer: "",
    private: %{}
  ]

  @doc """
  Same as `Mint.HTTP.connect/4`, but forces an HTTP/1 or HTTP/1.1 connection.

  This function doesn't support proxying.
  """
  @spec connect(Types.scheme(), String.t(), :inet.port_number(), keyword()) ::
          {:ok, t()} | {:error, Types.error()}
  def connect(scheme, hostname, port, opts \\ []) do
    # TODO: Also ALPN negotiate HTTP1?

    transport = scheme_to_transport(scheme)
    transport_opts = Keyword.get(opts, :transport_opts, [])

    with {:ok, socket} <- transport.connect(hostname, port, transport_opts) do
      initiate(transport, socket, hostname, port, opts)
    end
  end

  @doc false
  @spec upgrade(
          Types.scheme(),
          Mint.Types.socket(),
          Types.scheme(),
          String.t(),
          :inet.port_number(),
          keyword()
        ) :: {:ok, t()} | {:error, Types.error()}
  def upgrade(old_scheme, socket, new_scheme, hostname, port, opts) do
    # TODO: Also ALPN negotiate HTTP1?

    transport = scheme_to_transport(new_scheme)
    transport_opts = Keyword.get(opts, :transport_opts, [])

    with {:ok, socket} <- transport.upgrade(socket, old_scheme, hostname, port, transport_opts) do
      initiate(new_scheme, socket, hostname, port, opts)
    end
  end

  @doc false
  @impl true
  @spec initiate(
          Types.scheme(),
          Mint.Types.socket(),
          String.t(),
          :inet.port_number(),
          keyword()
        ) :: {:ok, t()} | {:error, Types.error()}
  def initiate(scheme, socket, hostname, _port, opts) do
    transport = scheme_to_transport(scheme)
    mode = Keyword.get(opts, :mode, :active)

    unless mode in [:active, :passive] do
      raise ArgumentError,
            "the :mode option must be either :active or :passive, got: #{inspect(mode)}"
    end

    with :ok <- inet_opts(transport, socket),
         :ok <- if(mode == :active, do: transport.setopts(socket, active: :once), else: :ok) do
      conn = %__MODULE__{
        transport: transport,
        socket: socket,
        mode: mode,
        host: hostname,
        state: :open
      }

      {:ok, conn}
    else
      {:error, reason} ->
        :ok = transport.close(socket)
        {:error, reason}
    end
  end

  @doc """
  See `Mint.HTTP.close/1`.
  """
  @impl true
  @spec close(t()) :: {:ok, t()}
  def close(conn)

  def close(%__MODULE__{state: :open} = conn) do
    conn = internal_close(conn)
    {:ok, conn}
  end

  def close(%__MODULE__{state: :closed} = conn) do
    {:ok, conn}
  end

  @doc """
  See `Mint.HTTP.open?/1`.
  """
  @impl true
  @spec open?(t(), :read | :write | :read_write) :: boolean()
  def open?(conn, type \\ :read_write)

  def open?(%__MODULE__{state: state}, type) when type in [:read, :write, :read_write] do
    state == :open
  end

  @doc """
  See `Mint.HTTP.request/5`.

  In HTTP/1 and HTTP/1.1, you can't open a new request if you're streaming the body of
  another request. If you try, the error reason `{:error, :request_body_is_streaming}` is
  returned.
  """
  @impl true
  @spec request(
          t(),
          method :: String.t(),
          path :: String.t(),
          Types.headers(),
          body :: iodata() | nil | :stream
        ) ::
          {:ok, t(), Types.request_ref()}
          | {:error, t(), Types.error()}
  def request(conn, method, path, headers, body \\ nil)

  def request(%__MODULE__{state: :closed} = conn, _method, _path, _headers, _body) do
    {:error, conn, wrap_error(:closed)}
  end

  def request(
        %__MODULE__{request: %{state: {:stream_request, _}}} = conn,
        _method,
        _path,
        _headers,
        _body
      ) do
    {:error, conn, wrap_error(:request_body_is_streaming)}
  end

  def request(%__MODULE__{} = conn, method, path, headers, body) do
    %__MODULE__{host: host, transport: transport, socket: socket} = conn

    headers =
      headers
      |> lower_header_keys()
      |> add_default_headers(host)

    with {:ok, headers, encoding} <- add_content_length_or_transfer_encoding(headers, body),
         {:ok, iodata} <- Request.encode(method, path, headers, body),
         :ok <- transport.send(socket, iodata) do
      request_ref = make_ref()
      request = new_request(request_ref, method, body, encoding)

      if conn.request == nil do
        conn = %__MODULE__{conn | request: request}
        {:ok, conn, request_ref}
      else
        requests = :queue.in(request, conn.requests)
        conn = %__MODULE__{conn | requests: requests}
        {:ok, conn, request_ref}
      end
    else
      {:error, %TransportError{reason: :closed} = error} ->
        {:error, %{conn | state: :closed}, error}

      {:error, %HTTPError{} = error} ->
        {:error, conn, error}

      {:error, reason} ->
        {:error, conn, wrap_error(reason)}
    end
  end

  @doc """
  See `Mint.HTTP.stream_request_body/3`.
  """
  @impl true
  @spec stream_request_body(t(), Types.request_ref(), iodata() | :eof) ::
          {:ok, t()} | {:error, t(), Types.error()}
  def stream_request_body(
        %__MODULE__{request: %{state: {:stream_request, :identity}, ref: ref}} = conn,
        ref,
        :eof
      ) do
    {:ok, put_in(conn.request.state, :status)}
  end

  def stream_request_body(
        %__MODULE__{request: %{state: {:stream_request, :identity}, ref: ref}} = conn,
        ref,
        body
      ) do
    case conn.transport.send(conn.socket, body) do
      :ok ->
        {:ok, conn}

      {:error, %TransportError{reason: :closed} = error} ->
        {:error, %{conn | state: :closed}, error}

      {:error, error} ->
        {:error, conn, error}
    end
  end

  def stream_request_body(
        %__MODULE__{request: %{state: {:stream_request, :chunked}, ref: ref}} = conn,
        ref,
        chunk
      ) do
    case conn.transport.send(conn.socket, Request.encode_chunk(chunk)) do
      :ok ->
        if chunk == :eof do
          {:ok, put_in(conn.request.state, :status)}
        else
          {:ok, conn}
        end

      {:error, %TransportError{reason: :closed} = error} ->
        {:error, %{conn | state: :closed}, error}

      {:error, error} ->
        {:error, conn, error}
    end
  end

  @doc """
  See `Mint.HTTP.stream/2`.
  """
  @impl true
  @spec stream(t(), term()) ::
          {:ok, t(), [Types.response()]}
          | {:error, t(), Types.error(), [Types.response()]}
          | :unknown
  def stream(conn, message)

  def stream(%__MODULE__{transport: transport, socket: socket} = conn, {tag, socket, data})
      when tag in [:tcp, :ssl] do
    result = handle_data(conn, data)

    if conn.mode == :active do
      # TODO: handle errors here.
      _ = transport.setopts(socket, active: :once)
    end

    result
  end

  def stream(%__MODULE__{socket: socket} = conn, {tag, socket})
      when tag in [:tcp_closed, :ssl_closed] do
    handle_close(conn)
  end

  def stream(%__MODULE__{socket: socket} = conn, {tag, socket, reason})
      when tag in [:tcp_error, :ssl_error] do
    handle_error(conn, conn.transport.wrap_error(reason))
  end

  def stream(%__MODULE__{}, _message) do
    :unknown
  end

  defp handle_data(%__MODULE__{request: nil} = conn, data) do
    conn = internal_close(conn)
    {:error, conn, wrap_error({:unexpected_data, data}), []}
  end

  defp handle_data(%__MODULE__{request: request} = conn, data) do
    data = maybe_concat(conn.buffer, data)

    case decode(request.state, conn, data, []) do
      {:ok, conn, responses} ->
        {:ok, conn, Enum.reverse(responses)}

      {:error, conn, reason, responses} ->
        conn = put_in(conn.state, :closed)
        {:error, conn, reason, responses}
    end
  end

  defp handle_close(%__MODULE__{request: request} = conn) do
    conn = put_in(conn.state, :closed)
    conn = request_done(conn)

    if request && request.body == :until_closed do
      conn = put_in(conn.state, :closed)
      {:ok, conn, [{:done, request.ref}]}
    else
      {:error, conn, conn.transport.wrap_error(:closed), []}
    end
  end

  defp handle_error(conn, error) do
    conn = put_in(conn.state, :closed)
    {:error, conn, error, []}
  end

  @doc """
  See `Mint.HTTP.recv/3`.
  """
  @impl true
  @spec recv(t(), non_neg_integer(), timeout()) ::
          {:ok, t(), [Types.response()]}
          | {:error, t(), Types.error(), [Types.response()]}
  # TODO: remove the check when we depend on Elixir 1.7+.
  if Version.match?(System.version(), ">= 1.7.0") do
    @doc since: "0.3.0"
  end

  def recv(conn, byte_count, timeout)

  def recv(%__MODULE__{mode: :passive} = conn, byte_count, timeout) do
    case conn.transport.recv(conn.socket, byte_count, timeout) do
      {:ok, data} -> handle_data(conn, data)
      {:error, error} -> handle_error(conn, error)
    end
  end

  def recv(_conn, _byte_count, _timeout) do
    raise ArgumentError,
          "can't use recv/3 to synchronously receive data when the mode is :active. " <>
            "Use Mint.HTTP.set_mode/2 to set the connection to passive mode"
  end

  @doc """
  See `Mint.HTTP.set_mode/2`.
  """
  # TODO: remove the check when we depend on Elixir 1.7+.
  if Version.match?(System.version(), ">= 1.7.0") do
    @doc since: "0.3.0"
  end

  @impl true
  @spec set_mode(t(), :active | :passive) :: {:ok, t()} | {:error, Types.error()}
  def set_mode(%__MODULE__{} = conn, mode) when mode in [:active, :passive] do
    active =
      case mode do
        :active -> :once
        :passive -> false
      end

    with :ok <- conn.transport.setopts(conn.socket, active: active) do
      {:ok, put_in(conn.mode, mode)}
    end
  end

  @doc """
  See `Mint.HTTP.controlling_process/2`.
  """
  # TODO: remove the check when we depend on Elixir 1.7+.
  if Version.match?(System.version(), ">= 1.7.0") do
    @doc since: "0.3.0"
  end

  @impl true
  @spec controlling_process(t(), pid()) :: {:ok, t()} | {:error, Types.error()}
  def controlling_process(%__MODULE__{} = conn, new_pid) when is_pid(new_pid) do
    with :ok <- conn.transport.controlling_process(conn.socket, new_pid) do
      {:ok, conn}
    end
  end

  @doc """
  See `Mint.HTTP.open_request_count/1`.

  In HTTP/1, the number of open requests is the number of pipelined requests.
  """
  @impl true
  @spec open_request_count(t()) :: non_neg_integer()
  def open_request_count(%__MODULE__{} = conn) do
    if is_nil(conn.request) do
      0
    else
      1 + :queue.len(conn.requests)
    end
  end

  @doc """
  See `Mint.HTTP.put_private/3`.
  """
  @impl true
  @spec put_private(t(), atom(), term()) :: t()
  def put_private(%__MODULE__{private: private} = conn, key, value) when is_atom(key) do
    %{conn | private: Map.put(private, key, value)}
  end

  @doc """
  See `Mint.HTTP.get_private/3`.
  """
  @impl true
  @spec get_private(t(), atom(), term()) :: term()
  def get_private(%__MODULE__{private: private} = _conn, key, default \\ nil) when is_atom(key) do
    Map.get(private, key, default)
  end

  @doc """
  See `Mint.HTTP.delete_private/2`.
  """
  @impl true
  @spec delete_private(t(), atom()) :: t()
  def delete_private(%__MODULE__{private: private} = conn, key) when is_atom(key) do
    %{conn | private: Map.delete(private, key)}
  end

  # Made public to be used with proxying.
  @doc false
  @impl true
  @spec get_socket(t()) :: Mint.Types.socket()
  def get_socket(%__MODULE__{socket: socket} = _conn) do
    socket
  end

  ## Helpers

  defp decode(:status, %{request: request} = conn, data, responses) do
    case Response.decode_status_line(data) do
      {:ok, {version, status, _reason}, rest} ->
        request = %{request | version: version, status: status, state: :headers}
        conn = %{conn | request: request}
        responses = [{:status, request.ref, status} | responses]
        decode(:headers, conn, rest, responses)

      :more ->
        conn = put_in(conn.buffer, data)
        {:ok, conn, responses}

      :error ->
        {:error, conn, wrap_error(:invalid_status_line), responses}
    end
  end

  defp decode(:headers, %{request: request} = conn, data, responses) do
    decode_headers(conn, request, data, responses, request.headers_buffer)
  end

  defp decode(:body, conn, data, responses) do
    case message_body(conn.request) do
      {:ok, body} ->
        conn = put_in(conn.request.body, body)
        decode_body(body, conn, data, conn.request.ref, responses)

      {:error, reason} ->
        {:error, conn, wrap_error(reason), responses}
    end
  end

  defp decode_headers(conn, request, data, responses, headers) do
    case Response.decode_header(data) do
      {:ok, {name, value}, rest} ->
        headers = [{name, value} | headers]

        case store_header(request, name, value) do
          {:ok, request} -> decode_headers(conn, request, rest, responses, headers)
          {:error, reason} -> {:error, conn, wrap_error(reason), responses}
        end

      {:ok, :eof, rest} ->
        responses = [{:headers, request.ref, Enum.reverse(headers)} | responses]
        request = %{request | state: :body, headers_buffer: []}
        conn = %{conn | buffer: "", request: request}
        decode(:body, conn, rest, responses)

      :more ->
        request = %{request | headers_buffer: headers}
        conn = %{conn | buffer: data, request: request}
        {:ok, conn, responses}

      :error ->
        {:error, conn, wrap_error(:invalid_header), responses}
    end
  end

  defp decode_body(:none, conn, data, request_ref, responses) do
    conn = put_in(conn.buffer, data)
    conn = request_done(conn)
    responses = [{:done, request_ref} | responses]
    {:ok, conn, responses}
  end

  defp decode_body(:until_closed, conn, data, _request_ref, responses) do
    {conn, responses} = add_body(conn, data, responses)
    {:ok, conn, responses}
  end

  defp decode_body({:content_length, length}, conn, data, request_ref, responses) do
    cond do
      length > byte_size(data) ->
        conn = put_in(conn.request.body, {:content_length, length - byte_size(data)})
        {conn, responses} = add_body(conn, data, responses)
        {:ok, conn, responses}

      length <= byte_size(data) ->
        <<body::binary-size(length), rest::binary>> = data
        {conn, responses} = add_body(conn, body, responses)
        conn = request_done(conn)
        responses = [{:done, request_ref} | responses]
        next_request(conn, rest, responses)
    end
  end

  defp decode_body({:chunked, nil}, conn, "", _request_ref, responses) do
    conn = put_in(conn.buffer, "")
    conn = put_in(conn.request.body, {:chunked, nil})
    {:ok, conn, responses}
  end

  defp decode_body({:chunked, nil}, conn, data, request_ref, responses) do
    case Integer.parse(data, 16) do
      {_size, ""} ->
        conn = put_in(conn.buffer, data)
        conn = put_in(conn.request.body, {:chunked, nil})
        {:ok, conn, responses}

      {0, rest} ->
        # Here, we manually collapse the body buffer since we're done with the body.
        {conn, responses} = collapse_body_buffer(conn, responses)
        decode_body({:chunked, :metadata, :trailer}, conn, rest, request_ref, responses)

      {size, rest} when size > 0 ->
        decode_body({:chunked, :metadata, size}, conn, rest, request_ref, responses)

      _other ->
        {:error, conn, wrap_error(:invalid_chunk_size), responses}
    end
  end

  defp decode_body({:chunked, :metadata, size}, conn, data, request_ref, responses) do
    case Parse.ignore_until_crlf(data) do
      {:ok, rest} ->
        decode_body({:chunked, size}, conn, rest, request_ref, responses)

      :more ->
        conn = put_in(conn.buffer, data)
        conn = put_in(conn.request.body, {:chunked, :metadata, size})
        {:ok, conn, responses}
    end
  end

  defp decode_body({:chunked, :trailer}, conn, data, _request_ref, responses) do
    decode_trailer_headers(conn, data, responses, conn.request.headers_buffer)
  end

  defp decode_body({:chunked, :crlf}, conn, data, request_ref, responses) do
    case data do
      <<"\r\n", rest::binary>> ->
        conn = put_in(conn.request.body, {:chunked, nil})
        decode_body({:chunked, nil}, conn, rest, request_ref, responses)

      _other when byte_size(data) < 2 ->
        conn = put_in(conn.buffer, data)
        {:ok, conn, responses}

      _other ->
        {:error, conn, wrap_error(:missing_crlf_after_chunk), responses}
    end
  end

  defp decode_body({:chunked, length}, conn, data, request_ref, responses) do
    cond do
      length > byte_size(data) ->
        conn = put_in(conn.buffer, "")
        conn = put_in(conn.request.body, {:chunked, length - byte_size(data)})
        {conn, responses} = add_body(conn, data, responses)
        {:ok, conn, responses}

      length <= byte_size(data) ->
        <<body::binary-size(length), rest::binary>> = data
        conn = add_body_to_buffer(conn, body)
        conn = put_in(conn.request.body, {:chunked, :crlf})
        decode_body({:chunked, :crlf}, conn, rest, request_ref, responses)
    end
  end

  defp decode_trailer_headers(conn, data, responses, headers) do
    case Response.decode_header(data) do
      {:ok, {name, value}, rest} ->
        headers = [{name, value} | headers]
        decode_trailer_headers(conn, rest, responses, headers)

      {:ok, :eof, rest} ->
        responses = [
          {:done, conn.request.ref}
          | add_trailing_headers(headers, conn.request.ref, responses)
        ]

        conn = request_done(conn)
        next_request(conn, rest, responses)

      :more ->
        request = %{conn.request | body: {:chunked, :trailer}, headers_buffer: headers}
        conn = %{conn | buffer: data, request: request}
        {:ok, conn, responses}

      :error ->
        {:error, conn, wrap_error(:invalid_trailer_header), responses}
    end
  end

  defp next_request(%{request: nil} = conn, data, responses) do
    # TODO: Figure out if we should keep buffering even though there are no
    # requests in flight
    {:ok, %{conn | buffer: data}, responses}
  end

  defp next_request(conn, data, responses) do
    decode(:status, %{conn | state: :status}, data, responses)
  end

  defp add_trailing_headers([], _request_ref, responses), do: responses

  defp add_trailing_headers(headers, request_ref, responses),
    do: [{:headers, request_ref, Enum.reverse(headers)} | responses]

  defp add_body(conn, data, responses) do
    conn = add_body_to_buffer(conn, data)
    collapse_body_buffer(conn, responses)
  end

  defp add_body_to_buffer(conn, data) do
    update_in(conn.request.data_buffer, &[&1 | data])
  end

  defp collapse_body_buffer(conn, responses) do
    case IO.iodata_to_binary(conn.request.data_buffer) do
      "" ->
        {conn, responses}

      data ->
        conn = put_in(conn.request.data_buffer, [])
        {conn, [{:data, conn.request.ref, data} | responses]}
    end
  end

  defp store_header(%{content_length: nil} = request, "content-length", value) do
    with {:ok, content_length} <- Parse.content_length_header(value),
         do: {:ok, %{request | content_length: content_length}}
  end

  defp store_header(%{connection: connection} = request, "connection", value) do
    with {:ok, connection_header} <- Parse.connection_header(value),
         do: {:ok, %{request | connection: connection ++ connection_header}}
  end

  defp store_header(%{transfer_encoding: transfer_encoding} = request, "transfer-encoding", value) do
    with {:ok, transfer_encoding_header} <- Parse.transfer_encoding_header(value),
         do: {:ok, %{request | transfer_encoding: transfer_encoding ++ transfer_encoding_header}}
  end

  defp store_header(_request, "content-length", _value) do
    {:error, :more_than_one_content_length_header}
  end

  defp store_header(request, _name, _value) do
    {:ok, request}
  end

  defp request_done(%{request: request} = conn) do
    conn = pop_request(conn)

    cond do
      !request -> conn
      "close" in request.connection -> internal_close(conn)
      request.version >= {1, 1} -> conn
      "keep-alive" in request.connection -> conn
      true -> internal_close(conn)
    end
  end

  defp pop_request(conn) do
    case :queue.out(conn.requests) do
      {{:value, request}, requests} ->
        %{conn | request: request, requests: requests}

      {:empty, requests} ->
        %{conn | request: nil, requests: requests}
    end
  end

  defp internal_close(conn) do
    if conn.buffer != "" do
      _ = Logger.debug(["Connection closed with data left in the buffer: ", inspect(conn.buffer)])
    end

    :ok = conn.transport.close(conn.socket)
    %{conn | state: :closed}
  end

  # RFC7230 3.3.3:
  # > If a message is received with both a Transfer-Encoding and a
  # > Content-Length header field, the Transfer-Encoding overrides the
  # > Content-Length.  Such a message might indicate an attempt to
  # > perform request smuggling (Section 9.5) or response splitting
  # > (Section 9.4) and ought to be handled as an error.  A sender MUST
  # > remove the received Content-Length field prior to forwarding such
  # > a message downstream.
  defp message_body(%{body: nil, method: method, status: status} = request) do
    cond do
      method == "HEAD" or status in 100..199 or status in [204, 304] ->
        {:ok, :none}

      # method == "CONNECT" and status in 200..299 -> nil

      request.transfer_encoding != [] && request.content_length ->
        {:error, :transfer_encoding_and_content_length}

      "chunked" == List.first(request.transfer_encoding) ->
        {:ok, {:chunked, nil}}

      request.content_length ->
        {:ok, {:content_length, request.content_length}}

      true ->
        {:ok, :until_closed}
    end
  end

  defp message_body(%{body: body}) do
    {:ok, body}
  end

  defp new_request(ref, method, body, encoding) do
    state =
      if body == :stream do
        {:stream_request, encoding}
      else
        :status
      end

    %{
      ref: ref,
      state: state,
      method: method,
      version: nil,
      status: nil,
      headers_buffer: [],
      data_buffer: [],
      content_length: nil,
      connection: [],
      transfer_encoding: [],
      body: nil
    }
  end

  defp lower_header_keys(headers) do
    for {name, value} <- headers, do: {Util.downcase_ascii(name), value}
  end

  defp add_default_headers(headers, host) do
    headers
    |> Util.put_new_header("user-agent", @user_agent)
    |> Util.put_new_header("host", host)
  end

  defp add_content_length_or_transfer_encoding(headers, :stream) do
    cond do
      List.keymember?(headers, "content-length", 0) ->
        {:ok, headers, :identity}

      found = List.keyfind(headers, "transfer-encoding", 0) ->
        {"transfer-encoding", value} = found

        with {:ok, tokens} <- Parse.transfer_encoding_header(value) do
          if "chunked" in tokens or "identity" in tokens do
            {:ok, headers, :identity}
          else
            new_transfer_encoding = {"transfer-encoding", value <> ",chunked"}
            headers = List.keyreplace(headers, "transfer-encoding", 0, new_transfer_encoding)
            {:ok, headers, :chunked}
          end
        end

      # If no content-length or transfer-encoding are present, assume
      # chunked transfer-encoding and handle the encoding ourselves.
      true ->
        headers = Util.put_new_header(headers, "transfer-encoding", "chunked")
        {:ok, headers, :chunked}
    end
  end

  defp add_content_length_or_transfer_encoding(headers, nil) do
    {:ok, headers, :identity}
  end

  defp add_content_length_or_transfer_encoding(headers, body) do
    length = body |> IO.iodata_length() |> Integer.to_string()
    {:ok, Util.put_new_header(headers, "content-length", length), :identity}
  end

  defp wrap_error(reason) do
    %HTTPError{reason: reason, module: __MODULE__}
  end

  @doc false
  def format_error(reason)

  def format_error(:closed) do
    "the connection is closed"
  end

  def format_error(:request_body_is_streaming) do
    "a request body is currently streaming, so no new requests can be issued"
  end

  def format_error({:unexpected_data, data}) do
    "received unexpected data: " <> inspect(data)
  end

  def format_error(:invalid_status_line) do
    "invalid status line"
  end

  def format_error(:invalid_header) do
    "invalid header"
  end

  def format_error({:invalid_request_target, target}) do
    "invalid request target: #{inspect(target)}"
  end

  def format_error({:invalid_header_name, name}) do
    "invalid header name: #{inspect(name)}"
  end

  def format_error({:invalid_header_value, name, value}) do
    "invalid value for header #{inspect(name)}: #{inspect(value)}"
  end

  def format_error(:invalid_chunk_size) do
    "invalid chunk size"
  end

  def format_error(:missing_crlf_after_chunk) do
    "missing CRLF after chunk"
  end

  def format_error(:invalid_trailer_header) do
    "invalid trailer header"
  end

  def format_error(:more_than_one_content_length_header) do
    "the response contains two or more Content-Length headers"
  end

  def format_error(:transfer_encoding_and_content_length) do
    "the response contained both a Transfer-Encoding header as well as a Content-Length header"
  end

  def format_error({:invalid_content_length_header, value}) do
    "invalid Content-Length header: #{inspect(value)}"
  end

  def format_error(:empty_token_list) do
    "header should contain a list of values, but it doesn't"
  end

  def format_error({:invalid_token_list, string}) do
    "header contains invalid tokens: #{inspect(string)}"
  end
end

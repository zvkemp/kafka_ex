defmodule KafkaEx.Server0P9P0 do
  @moduledoc """
  Implements kafkaEx.Server behaviors for kafka 0.9.0 API.
  """
  use KafkaEx.Server
  alias KafkaEx.Protocol.ConsumerMetadata
  alias KafkaEx.Protocol.ConsumerMetadata.Response, as: ConsumerMetadataResponse
  alias KafkaEx.Protocol.Heartbeat
  alias KafkaEx.Protocol.JoinGroup
  alias KafkaEx.Protocol.JoinGroup.Request, as: JoinGroupRequest
  alias KafkaEx.Protocol.LeaveGroup
  alias KafkaEx.Protocol.Metadata.Broker
  alias KafkaEx.Protocol.SyncGroup
  alias KafkaEx.Server.State
  alias KafkaEx.NetworkClient
  alias KafkaEx.Server0P8P2

  @consumer_group_update_interval 30_000

  def start_link(args, name \\ __MODULE__)

  def start_link(args, :no_name) do
    GenServer.start_link(__MODULE__, [args])
  end
  def start_link(args, name) do
    GenServer.start_link(__MODULE__, [args, name], [name: name])
  end

  # The functions below are all defined in KafkaEx.Server0P8P2 and their
  # implementation is exactly same across both versions of kafka.

  defdelegate kafka_server_consumer_group(state), to: Server0P8P2
  defdelegate kafka_server_fetch(fetch_request, state), to: Server0P8P2
  defdelegate kafka_server_offset_fetch(offset_fetch, state), to: Server0P8P2
  defdelegate kafka_server_offset_commit(offset_commit_request, state), to: Server0P8P2
  defdelegate kafka_server_consumer_group_metadata(state), to: Server0P8P2
  defdelegate kafka_server_start_streaming(fetch_request, state), to: Server0P8P2
  defdelegate kafka_server_update_consumer_metadata(state), to: Server0P8P2

  def kafka_server_init([args]) do
    kafka_server_init([args, self()])
  end

  def kafka_server_init([args, name]) do
    uris = Keyword.get(args, :uris, [])
    metadata_update_interval = Keyword.get(args, :metadata_update_interval, @metadata_update_interval)
    consumer_group_update_interval = Keyword.get(args, :consumer_group_update_interval, @consumer_group_update_interval)
    # this should have already been validated, but it's possible someone could
    # try to short-circuit the start call
    consumer_group = Keyword.get(args, :consumer_group)
    true = KafkaEx.valid_consumer_group?(consumer_group)

    use_ssl = Keyword.get(args, :use_ssl, false)
    ssl_options = Keyword.get(args, :ssl_options, [])

    brokers = Enum.map(uris, fn({host, port}) -> %Broker{host: host, port: port, socket: NetworkClient.create_socket(host, port, ssl_options, use_ssl)} end)
    {correlation_id, metadata} = retrieve_metadata(brokers, 0, sync_timeout())
    state = %State{metadata: metadata, brokers: brokers, correlation_id: correlation_id, consumer_group: consumer_group, metadata_update_interval: metadata_update_interval, consumer_group_update_interval: consumer_group_update_interval, worker_name: name, ssl_options: ssl_options, use_ssl: use_ssl}
    # Get the initial "real" broker list and start a regular refresh cycle.
    state = update_metadata(state)
    {:ok, _} = :timer.send_interval(state.metadata_update_interval, :update_metadata)

    # only start the consumer group update cycle if we are using consumer groups
    if consumer_group?(state) do
      {:ok, _} = :timer.send_interval(state.consumer_group_update_interval, :update_consumer_metadata)
    end

    {:ok, state}
  end

  def kafka_server_join_group(topics, session_timeout, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = JoinGroup.create_request(
      %JoinGroupRequest{
        correlation_id: state.correlation_id,
        client_id: @client_id, member_id: "",
        group_name: state.consumer_group,
        topics: topics, session_timeout: session_timeout
      }
    )
    response = broker
      |> NetworkClient.send_sync_request(request, sync_timeout())
      |> JoinGroup.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  def kafka_server_sync_group(group_name, generation_id, member_id, assignments, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = SyncGroup.create_request(state.correlation_id, @client_id, group_name, generation_id, member_id, assignments)
    response = broker
      |> NetworkClient.send_sync_request(request, sync_timeout())
      |> SyncGroup.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  def kafka_server_leave_group(group_name, member_id, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = LeaveGroup.create_request(state.correlation_id, @client_id, group_name, member_id)
    response = broker
      |> NetworkClient.send_sync_request(request, sync_timeout())
      |> LeaveGroup.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  def kafka_server_heartbeat(group_name, generation_id, member_id, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = Heartbeat.create_request(state.correlation_id, @client_id, member_id, group_name, generation_id)
    response = broker
      |> NetworkClient.send_sync_request(request, sync_timeout())
      |> Heartbeat.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  defp update_consumer_metadata(state), do: update_consumer_metadata(state, @retry_count, 0)

  defp update_consumer_metadata(state = %State{consumer_group: consumer_group}, 0, error_code) do
    Logger.log(:error, "Fetching consumer_group #{consumer_group} metadata failed with error_code #{inspect error_code}")
    {%ConsumerMetadataResponse{error_code: error_code}, state}
  end

  defp update_consumer_metadata(state = %State{consumer_group: consumer_group, correlation_id: correlation_id}, retry, _error_code) do
    response = correlation_id
      |> ConsumerMetadata.create_request(@client_id, consumer_group)
      |> first_broker_response(state)
      |> ConsumerMetadata.parse_response

    case response.error_code do
      :no_error -> {response, %{state | consumer_metadata: response, correlation_id: state.correlation_id + 1}}
      _ -> :timer.sleep(400)
        update_consumer_metadata(%{state | correlation_id: state.correlation_id + 1}, retry - 1, response.error_code)
    end
  end

  defp broker_for_consumer_group(state) do
    ConsumerMetadataResponse.broker_for_consumer_group(state.brokers, state.consumer_metadata)
  end

  # refactored from two versions, one that used the first broker as valid answer, hence
  # the optional extra flag to do that. Wraps broker_for_consumer_group with an update
  # call if no broker was found.
  defp broker_for_consumer_group_with_update(state, use_first_as_default \\ false) do
    case broker_for_consumer_group(state) do
      nil ->
        {_, updated_state} = update_consumer_metadata(state)
        default_broker = if use_first_as_default, do: hd(state.brokers), else: nil
        {broker_for_consumer_group(updated_state) || default_broker, updated_state}
      broker ->
        {broker, state}
    end
  end

  # note within the genserver state, we've already validated the
  # consumer group, so it can only be either :no_consumer_group or a
  # valid binary consumer group name
  def consumer_group?(%State{consumer_group: :no_consumer_group}), do: false
  def consumer_group?(_), do: true

  def consumer_group_if_auto_commit?(true, state) do
    consumer_group?(state)
  end
  def consumer_group_if_auto_commit?(false, _state) do
    true
  end

  defp first_broker_response(request, state) do
    first_broker_response(request, state.brokers, sync_timeout())
  end
end

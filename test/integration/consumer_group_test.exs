defmodule KafkaEx.ConsumerGroup.Test do
  alias KafkaEx.Protocol, as: Proto
  alias KafkaEx.Config
  use ExUnit.Case
  import TestHelper

  @moduletag :consumer_group

  test "fetching the consumer group from the default worker" do
    assert Application.get_env(:kafka_ex, :consumer_group) ==
      KafkaEx.consumer_group()
  end

  test "create_worker returns an error when an invalid consumer group is provided" do
    assert {:error, :invalid_consumer_group} == KafkaEx.create_worker(:francine, consumer_group: 0)
  end

  test "create_worker allows us to disable the consumer group" do
    {:ok, pid} = KafkaEx.create_worker(:barney, consumer_group: :no_consumer_group)

    consumer_group = :sys.get_state(pid).consumer_group
    assert consumer_group == :no_consumer_group
  end

  test "create_worker allows us to provide a consumer group" do
    {:ok, pid} = KafkaEx.create_worker(:bah, consumer_group: "my_consumer_group")
    consumer_group = :sys.get_state(pid).consumer_group

    assert consumer_group == "my_consumer_group"
  end

  test "create_worker allows custom consumer_group_update_interval" do
    {:ok, pid} = KafkaEx.create_worker(:consumer_group_update_interval_custom, uris: uris(), consumer_group_update_interval: 10)
    consumer_group_update_interval = :sys.get_state(pid).consumer_group_update_interval

    assert consumer_group_update_interval == 10
  end

  test "create_worker provides a default consumer_group_update_interval of '30000'" do
    {:ok, pid} = KafkaEx.create_worker(:de, uris: uris())
    consumer_group_update_interval = :sys.get_state(pid).consumer_group_update_interval

    assert consumer_group_update_interval == 30000
  end

  test "create_worker provides a default consumer_group of 'kafka_ex'" do
    {:ok, pid} = KafkaEx.create_worker(:baz, uris: uris())
    consumer_group = :sys.get_state(pid).consumer_group

    assert consumer_group == "kafka_ex"
  end

  test "create_worker takes a consumer_group option and sets that as the consumer_group of the worker" do
    {:ok, pid} = KafkaEx.create_worker(:joe, [uris: uris(), consumer_group: "foo"])
    consumer_group = :sys.get_state(pid).consumer_group

    assert consumer_group == "foo"
  end

  test "asking the worker for the name of its consumer group" do
    consumer_group = "this_is_my_consumer_group"
    worker_name = :consumer_group_reader_test
    {:ok, _pid} = KafkaEx.create_worker(worker_name,
                                        consumer_group: consumer_group)

    assert consumer_group == KafkaEx.consumer_group(worker_name)
  end

  test "consumer_group_metadata works" do
    random_string = generate_random_string()
    KafkaEx.produce(%Proto.Produce.Request{topic: "food", partition: 0, required_acks: 1, messages: [%Proto.Produce.Message{value: "hey"}]})
    KafkaEx.fetch("food", 0, offset: 0)
    KafkaEx.create_worker(:consumer_group_metadata_worker, consumer_group: random_string, uris: Application.get_env(:kafka_ex, :brokers))
    pid = Process.whereis(:consumer_group_metadata_worker)
    metadata = KafkaEx.consumer_group_metadata(:consumer_group_metadata_worker, random_string)
    consumer_group_metadata = :sys.get_state(pid).consumer_metadata

    assert metadata != %Proto.ConsumerMetadata.Response{}
    assert metadata.coordinator_host != nil
    assert metadata.error_code == :no_error
    assert metadata == consumer_group_metadata
  end

  #update_consumer_metadata
  test "worker updates metadata after specified interval" do
    {:ok, pid} = KafkaEx.create_worker(:update_consumer_metadata, [uris: uris(), consumer_group: "kafka_ex", consumer_group_update_interval: 100])
    consumer_metadata = %KafkaEx.Protocol.ConsumerMetadata.Response{}
    :sys.replace_state(pid, fn(state) ->
      %{state | :consumer_metadata => consumer_metadata}
    end)
    :timer.sleep(105)
    new_consumer_metadata = :sys.get_state(pid).consumer_metadata

    refute new_consumer_metadata == consumer_metadata
  end

  test "worker does not update metadata when consumer_group is disabled" do
    {:ok, pid} = KafkaEx.create_worker(:no_consumer_metadata_update, [uris: uris(), consumer_group: :no_consumer_group, consumer_group_update_interval: 100])
    consumer_metadata = %KafkaEx.Protocol.ConsumerMetadata.Response{}
    :sys.replace_state(pid, fn(state) ->
      %{state | :consumer_metadata => consumer_metadata}
    end)
    :timer.sleep(105)
    new_consumer_metadata = :sys.get_state(pid).consumer_metadata

    assert new_consumer_metadata == consumer_metadata
  end

  #fetch
  test "fetch auto_commits offset by default" do
    worker_name = :fetch_test_worker
    topic = "kafka_ex_consumer_group_test"
    consumer_group = "auto_commit_consumer_group"
    KafkaEx.create_worker(worker_name,
                          uris: Application.get_env(:kafka_ex, :brokers),
                          consumer_group: consumer_group)

    offset_before = TestHelper.latest_offset_number(topic, 0, worker_name)
    Enum.each(1..10, fn _ ->
      msg = %Proto.Produce.Message{value: "hey #{inspect :os.timestamp}"}
      KafkaEx.produce(%Proto.Produce.Request{topic: topic,
                                             partition: 0,
                                             required_acks: 1,
                                             messages: [msg]},
                      worker_name: worker_name)
    end)

    offset_after = TestHelper.latest_offset_number(topic, 0, worker_name)
    assert offset_after == offset_before + 10

    [logs] = KafkaEx.fetch(topic,
                           0,
                           offset: offset_before,
                           worker_name: worker_name)
    [partition] = logs.partitions
    message_set = partition.message_set
    assert 10 == length(message_set)

    last_message = List.last(message_set)
    offset_of_last_message = last_message.offset

    offset_request = %Proto.OffsetFetch.Request{topic: topic,
                                                partition: 0,
                                                consumer_group: consumer_group}

    [offset_fetch_response] = KafkaEx.offset_fetch(worker_name, offset_request)
    [partition] = offset_fetch_response.partitions
    error_code = partition.error_code
    offset_fetch_response_offset = partition.offset

    assert error_code == :no_error
    assert offset_of_last_message == offset_fetch_response_offset
  end

  test "fetch starts consuming from last committed offset" do
    random_string = generate_random_string()
    KafkaEx.create_worker(:fetch_test_committed_worker)
    Enum.each(1..10, fn _ -> KafkaEx.produce(%Proto.Produce.Request{topic: random_string, partition: 0, required_acks: 1, messages: [%Proto.Produce.Message{value: "hey"}]}) end)
    KafkaEx.offset_commit(:fetch_test_committed_worker, %Proto.OffsetCommit.Request{topic: random_string, offset: 3, partition: 0})
    logs = KafkaEx.fetch(random_string, 0, worker: :fetch_test_committed_worker) |> hd |> Map.get(:partitions) |> hd |> Map.get(:message_set)

    first_message = logs |> hd

    assert first_message.offset == 4
    assert length(logs) == 6
  end

  test "fetch does not commit offset with auto_commit is set to false" do
    topic = generate_random_string()
    worker_name = :fetch_no_auto_commit_worker
    KafkaEx.create_worker(worker_name)
    Enum.each(1..10, fn _ -> KafkaEx.produce(%Proto.Produce.Request{topic: topic, partition: 0, required_acks: 1, messages: [%Proto.Produce.Message{value: "hey"}]}, worker_name: worker_name) end)
    offset = KafkaEx.fetch(topic, 0, offset: 0, worker: worker_name, auto_commit: false) |> hd |> Map.get(:partitions) |> hd |> Map.get(:message_set) |> Enum.reverse |> hd |> Map.get(:offset)
    offset_fetch_response = KafkaEx.offset_fetch(worker_name, %Proto.OffsetFetch.Request{topic: topic, partition: 0}) |> hd
    offset_fetch_response_offset = offset_fetch_response.partitions |> hd |> Map.get(:offset)

    refute offset == offset_fetch_response_offset
  end

  #offset_fetch
  test "offset_fetch does not override consumer_group" do
    topic = generate_random_string()
    worker_name = :offset_fetch_consumer_group
    consumer_group = "bar#{topic}"
    KafkaEx.create_worker(worker_name, consumer_group: consumer_group, uris: Application.get_env(:kafka_ex, :brokers))
    Enum.each(1..10, fn _ -> KafkaEx.produce(%Proto.Produce.Request{topic: topic, required_acks: 1, partition: 0, messages: [%Proto.Produce.Message{value: "hey"}]}, worker_name: worker_name) end)

    KafkaEx.offset_fetch(worker_name, %KafkaEx.Protocol.OffsetFetch.Request{topic: topic, partition: 0})

    assert :sys.get_state(:offset_fetch_consumer_group).consumer_group == consumer_group
  end

  #offset_commit
  test "offset_commit commits an offset and offset_fetch retrieves the committed offset" do
    random_string = generate_random_string()
    Enum.each(1..10, fn _ -> KafkaEx.produce(%Proto.Produce.Request{topic: random_string, partition: 0, required_acks: 1, messages: [%Proto.Produce.Message{value: "hey"}]}) end)
    assert KafkaEx.offset_commit(Config.default_worker, %Proto.OffsetCommit.Request{topic: random_string, offset: 9, partition: 0}) ==
      [%Proto.OffsetCommit.Response{partitions: [0], topic: random_string}]
    assert KafkaEx.offset_fetch(Config.default_worker, %Proto.OffsetFetch.Request{topic: random_string, partition: 0}) ==
      [%Proto.OffsetFetch.Response{partitions: [%{metadata: "", error_code: :no_error, offset: 9, partition: 0}], topic: random_string}]
  end

  #stream
  test "stream auto_commits offset by default" do
    random_string = generate_random_string()
    KafkaEx.create_worker(:stream_auto_commit, uris: uris(), consumer_group: "kafka_ex")
    KafkaEx.produce(%Proto.Produce.Request{topic: random_string, partition: 0, required_acks: 1, messages: [
        %Proto.Produce.Message{value: "hey"},
        %Proto.Produce.Message{value: "hi"},
      ]
    })
    stream = KafkaEx.stream(random_string, 0, worker_name: :stream_auto_commit, offset: 0)
    log = TestHelper.wait_for_any(
      fn() -> stream |> Enum.take(2) end
    )

    refute Enum.empty?(log)

    offset_fetch_response = KafkaEx.offset_fetch(:stream_auto_commit, %Proto.OffsetFetch.Request{topic: random_string, partition: 0}) |> hd
    error_code = offset_fetch_response.partitions |> hd |> Map.get(:error_code)
    offset = offset_fetch_response.partitions |> hd |> Map.get(:offset)

    assert error_code == :no_error
    refute offset == 0
  end

  test "stream starts consuming from the next offset" do
    random_string = generate_random_string()
    consumer_group = "kafka_ex"
    worker_name = :stream_last_committed_offset
    KafkaEx.create_worker(worker_name, uris: uris(), consumer_group: consumer_group)
    Enum.each(1..10, fn _ -> KafkaEx.produce(%Proto.Produce.Request{topic: random_string, partition: 0, required_acks: 1, messages: [%Proto.Produce.Message{value: "hey"}]}, worker_name: worker_name) end)
    KafkaEx.offset_commit(worker_name, %Proto.OffsetCommit.Request{topic: random_string, partition: 0, offset: 3})

    # make sure the offset commit is actually committed before we
    # start streaming again
    :ok = TestHelper.wait_for(fn() ->
      3 == TestHelper.latest_consumer_offset_number(random_string, 0, consumer_group, worker_name)
    end)

    stream = KafkaEx.stream(random_string, 0, worker_name: worker_name)
    log = TestHelper.wait_for_any(
      fn() -> stream |> Enum.take(2) end
    )

    refute Enum.empty?(log)
    first_message = log |> hd
    assert first_message.offset == 4
  end

  test "stream does not commit offset with auto_commit is set to false" do
    random_string = generate_random_string()
    KafkaEx.create_worker(:stream_no_auto_commit, uris: uris())
    Enum.each(1..10, fn _ -> KafkaEx.produce(%Proto.Produce.Request{topic: random_string, partition: 0, required_acks: 1, messages: [%Proto.Produce.Message{value: "hey"}]}) end)
    stream = KafkaEx.stream(random_string, 0, worker_name: :stream_no_auto_commit, auto_commit: false, offset: 0)

    # make sure we consume at least one message before we assert that there is no offset committed
    _log = TestHelper.wait_for_any(
      fn() -> stream |> Enum.take(2) end
    )

    offset_fetch_response = KafkaEx.offset_fetch(:stream_no_auto_commit, %Proto.OffsetFetch.Request{topic: random_string, partition: 0}) |> hd
    offset_fetch_response.partitions |> hd |> Map.get(:error_code)
    offset_fetch_response_offset = offset_fetch_response.partitions |> hd |> Map.get(:offset)

    assert 0 >= offset_fetch_response_offset
  end
end

import serialization, json_serialization, stew/endians2, stew/byteutils
import libp2p, testground_sdk, libp2p/protocols/pubsub/rpc/messages
import chronos
import sequtils, hashes
from times import getTime, toUnix, fromUnix, `-`, initTime, `$`

type
  PeerData = object
    id {.serializedFieldName: "ID".}: string
    addrs {.serializedFieldName: "Addrs".}: seq[string]

proc msgIdProvider(m: Message): Result[MessageID, ValidationResult] =
  return ok(($m.data.hash).toBytes())

testground(client):
  let addresses = getInterfaces().filterIt(it.name == "eth1").mapIt(it.addresses)
  if addresses.len < 1 or addresses[0].len < 1:
    quit "Can't find local ip!"

  let peersTopic = client.subscribe("peers", PeerData)

  let
    myId = await client.signal("initialized_global")
    isPublisher = myId <= client.param(int, "publisher_count")
    rng = libp2p.newRng()
    address = addresses[0][0].host
    switch =
      SwitchBuilder
        .new()
        .withAddress(MultiAddress.init(address).tryGet())
        .withRng(rng)
        #.withYamux()
        .withMplex()
        .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
        #.withPlainText()
        .withNoise()
        .build()
    gossipSub = GossipSub.init(
      switch = switch,
      triggerSelf = true,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
      )
  gossipSub.parameters.floodPublish = false
  gossipSub.parameters.heartbeatInterval = 5.minutes

  proc messageHandler(topic: string, data: seq[byte]) {.async.} =
    let
      sentUint = uint64.fromBytesLE(data)
      sentMoment = nanoseconds(int64(uint64.fromBytesLE(data)))
      sentNanosecs = nanoseconds(sentMoment - seconds(sentMoment.seconds))
      sentDate = initTime(sentMoment.seconds, sentNanosecs)
      diff = getTime() - sentDate
    echo sentUint, ": ", diff
  gossipSub.subscribe("test", messageHandler)
  switch.mount(gossipSub)
  await switch.start()
  #TODO
  #defer: await switch.stop()

  await client.publish("peers",
    PeerData(
      id: $switch.peerInfo.peerId,
      addrs: switch.peerInfo.addrs.mapIt($it)
    )
  )
  echo "Listening on ", switch.peerInfo.addrs
  echo myId, ", ", isPublisher

  var peersInfo: seq[PeerData]
  while peersInfo.len < client.testInstanceCount:
    peersInfo.add(await peersTopic.popFirst())

  rng.shuffle(peersInfo)

  let connectTo = client.param(int, "connection_count")
  var connected = 0
  for peerInfo in peersInfo:
    if peerInfo.id == $switch.peerInfo.peerId: continue

    if connected >= connectTo: break
    let
      peerId = PeerId.init(peerInfo.id).tryGet()
      addrs = peerInfo.addrs.mapIt(MultiAddress.init(it).tryGet())
    try:
      await switch.connect(peerId, addrs)
      connected.inc()
    except CatchableError as exc:
      echo "Failed to dial", exc.msg

  await client.updateNetworkParameter(
    NetworkConf(
      network: "default",
      enable: true,
      callback_state: "connected",
      callback_target: some client.testInstanceCount,
      routing_policy: "accept_all",
      default: LinkShape(
        latency: 100000000,
      #  jitter: 100000000,
      )

    )
  )

  await client.waitForBarrier("connected", client.testInstanceCount)

  if isPublisher:
    let maxMessageDelay = client.param(int, "max_message_delay")
    for _ in 0 ..< client.param(int, "message_count"):
      await sleepAsync(milliseconds(rng.rand(maxMessageDelay)))
      let
        now = getTime()
        nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
        nowBytes = @(toBytesLE(uint64(nowInt.nanoseconds)))
      #echo "sending ", uint64(nowInt.nanoseconds)
      doAssert((await gossipSub.publish("test", nowBytes)) > 0)

  discard await client.signalAndWait("done", client.testInstanceCount)

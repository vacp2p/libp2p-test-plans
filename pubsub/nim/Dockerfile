ARG NimVersion="latest"
FROM nimlang/nim:${NimVersion}-ubuntu as builder

RUN nimble install -y "https://github.com/status-im/testground-nim-sdk@#872753fe083c470ecce8e3a90091cf8dee7840ac"
RUN apt update && apt install -y iproute2

#ARG Libp2pVersion="#fc5a5731"
#RUN nimble install -y "libp2p@${Libp2pVersion}"
FROM builder

ARG PLAN_PATH="./"
COPY ./plan/${PLAN_PATH} ./plan
RUN cd plan && nimble install -dy && \
  nim c -d:chronicles_log_level=NOTICE \
  -p:libp2p \
  --NimblePath:libp2p/nimbledeps/pkgs \
  -d:metrics \
  --threads:on \
  -d:withoutPCRE \
  -d:libp2p_network_protocols_metrics \
  -d:release \
  main.nim

ENTRYPOINT ["plan/main"]

# raft

Adjoint's implementation of the Raft protocol

# getting started

To run an example (currently without client request handling):

1) First, build the example executable:
```$ stack build ```

2) Then, in separate terminals, run some raft nodes: 

The format of the cmd line invocation is:
``` raft-example <node-id> <peer-1-node-id> ... <peer-n-node-id> ```

```$ stack exec raft-example localhost:3001 localhost:3002```

```$ stack exec raft-example localhost:3002 localhost:3001```

The first node spawned should immediately become leader and stay that way for
the remainder of the session. This is a local network test, and no client
requests are currently being handled, therefore the leader should always be able
to transmit `AppendEntries` RPCs in time.

#!/usr/bin/env bun
import { startRpcServer } from './rpc/server.ts';

const parentPid = process.env.FLUTTER_PARENT_PID;
if (parentPid) {
  setInterval(() => {
    try {
      process.kill(parseInt(parentPid, 10), 0);
    } catch (e) {
      process.exit(0);
    }
  }, 3000).unref();
}

startRpcServer();

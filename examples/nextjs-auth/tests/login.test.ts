import { describe, expect, it } from "vitest";
import { authenticate } from "../lib/auth";

describe("authenticate", () => {
  it("authenticates valid credentials", async () => {
    const user = await authenticate("alice", "password123");

    expect(user?.username).toBe("alice");
  });

  it("rejects invalid credentials", async () => {
    const user = await authenticate("alice", "wrong-password");

    expect(user).toBeNull();
  });
});

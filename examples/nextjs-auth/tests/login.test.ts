import { describe, expect, it } from "vitest";
import { authenticate, isPasswordValid } from "../lib/auth";

describe("isPasswordValid", () => {
  it("rejects passwords containing only alphanumeric characters", () => {
    expect(isPasswordValid("password123")).toBe(false);
  });

  it("accepts passwords containing a non-alphanumeric character", () => {
    expect(isPasswordValid("password123!")).toBe(true);
  });
});

describe("authenticate", () => {
  it("authenticates valid credentials", async () => {
    const user = await authenticate("alice", "password123!");

    expect(user?.username).toBe("alice");
  });

  it("rejects invalid credentials", async () => {
    const user = await authenticate("alice", "wrong-password");

    expect(user).toBeNull();
  });
});

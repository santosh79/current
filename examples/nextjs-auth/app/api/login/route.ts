import { authenticate } from "../../../../lib/auth";
import { isCsrfRequestValid } from "../../../../lib/csrf";
import { logFailedLogin } from "../../../../lib/logger";

export async function POST(request: Request) {
  if (!isCsrfRequestValid(request)) {
    return Response.json(
      { error: "Invalid CSRF origin" },
      { status: 403 }
    );
  }

  const { username, password } = await request.json();

  const user = await authenticate(username, password);

  if (!user) {
    logFailedLogin(username);

    return Response.json(
      { error: "Invalid credentials" },
      { status: 401 }
    );
  }

  return Response.json({
    id: user.id,
    username: user.username
  });
}


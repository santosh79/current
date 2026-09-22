import { authenticate } from "../../../../lib/auth";

export async function POST(request: Request) {
  const { username, password } = await request.json();

  const user = await authenticate(username, password);

  if (!user) {
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


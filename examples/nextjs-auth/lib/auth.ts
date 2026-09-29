type User = {
  id: number;
  username: string;
  password: string;
};

const users: User[] = [
  {
    id: 1,
    username: "alice",
    password: "password123!"
  }
];

export function isPasswordValid(password: string): boolean {
  return /[^a-zA-Z0-9]/.test(password);
}

export async function authenticate(
  username: string,
  password: string
): Promise<User | null> {
  if (!isPasswordValid(password)) {
    return null;
  }

  return (
    users.find(
      user =>
        user.username === username &&
        user.password === password
    ) ?? null
  );
}



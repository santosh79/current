type User = {
  id: number;
  username: string;
  password: string;
};

const users: User[] = [
  {
    id: 1,
    username: "alice",
    password: "password123"
  }
];

export async function authenticate(
  username: string,
  password: string
): Promise<User | null> {
  return (
    users.find(
      user =>
        user.username === username &&
        user.password === password
    ) ?? null
  );
}



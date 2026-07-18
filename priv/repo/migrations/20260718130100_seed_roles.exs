defmodule TragarAi.Repo.Migrations.SeedRoles do
  use Ecto.Migration

  # Seed the three roles + their page permissions, and grant the admin (wildcard)
  # role to every existing user so nobody is locked out when the gates go live.
  # Raw SQL with fixed role UUIDs so it's deterministic and needs no app boot.
  @admin "11111111-1111-1111-1111-111111111111"
  @csd "22222222-2222-2222-2222-222222222222"
  @operations "33333333-3333-3333-3333-333333333333"

  def up do
    ts = "now() at time zone 'utc'"

    execute("""
    INSERT INTO roles (id, name, description, is_admin, inserted_at, updated_at) VALUES
      ('#{@admin}', 'admin', 'Full access to all pages', true, #{ts}, #{ts}),
      ('#{@csd}', 'csd', 'Collections view (shared display)', false, #{ts}, #{ts}),
      ('#{@operations}', 'operations', 'Supplier selection (ops)', false, #{ts}, #{ts})
    ON CONFLICT (name) DO NOTHING;
    """)

    # csd → collections; operations → supplier_ops. admin is wildcard (no rows).
    execute("""
    INSERT INTO role_permissions (id, role_id, page_key, inserted_at, updated_at) VALUES
      (gen_random_uuid(), '#{@csd}', 'collections', #{ts}, #{ts}),
      (gen_random_uuid(), '#{@operations}', 'supplier_ops', #{ts}, #{ts})
    ON CONFLICT (role_id, page_key) DO NOTHING;
    """)

    # Grant admin to all current users (they were the trusted margin admins).
    execute("""
    INSERT INTO user_roles (id, user_id, role_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), u.id, '#{@admin}', #{ts}, #{ts}
    FROM users u
    ON CONFLICT (user_id, role_id) DO NOTHING;
    """)
  end

  def down do
    execute("DELETE FROM user_roles WHERE role_id IN ('#{@admin}', '#{@csd}', '#{@operations}');")
    execute("DELETE FROM role_permissions WHERE role_id IN ('#{@csd}', '#{@operations}');")
    execute("DELETE FROM roles WHERE id IN ('#{@admin}', '#{@csd}', '#{@operations}');")
  end
end

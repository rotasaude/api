# spec/rls/tenant_isolation_spec.rb
require "rails_helper"

# Invariantes do ADR-0019:
#  1. Sem tenant → query levanta (falha fechada).
#  2. Setar tenant A não vê linha de B (USING).
#  3. Setar tenant A não consegue inserir linha de B (WITH CHECK).
#  4. Conexão admin (BYPASSRLS) vê tudo.
RSpec.describe "RLS tenant isolation", type: :model do
  # Não usar transactional fixtures: este spec controla transações manualmente
  # para poder usar SET LOCAL e testar RLS em conexões diferentes.
  self.use_transactional_tests = false

  # Cria fixtures via SQL direto pela conexão admin (BYPASSRLS),
  # contornando o RLS que estaria ativo na conexão primary.
  before do
    # Garantir que Current está limpo (pode ter sido deixado por outros testes)
    Current.reset

    # Limpar e inserir via conexão admin (BYPASSRLS)
    admin_conn = ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection
    end

    admin_conn.execute("DELETE FROM conversations")
    admin_conn.execute("DELETE FROM municipalities")
    admin_conn.execute(<<~SQL.squish)
      INSERT INTO municipalities (id, name, slug, created_at, updated_at)
      VALUES (gen_random_uuid(), 'A', 'a', now(), now()),
             (gen_random_uuid(), 'B', 'b', now(), now())
    SQL
    @a_id = admin_conn.select_value("SELECT id FROM municipalities WHERE slug='a'")
    @b_id = admin_conn.select_value("SELECT id FROM municipalities WHERE slug='b'")
    admin_conn.execute(<<~SQL.squish)
      INSERT INTO conversations (id, municipality_id, phone, state, created_at, updated_at)
      VALUES (gen_random_uuid(), '#{@a_id}', 'enc-a', 'greeting', now(), now()),
             (gen_random_uuid(), '#{@b_id}', 'enc-b', 'greeting', now(), now())
    SQL
  end

  after do
    # Limpar após cada exemplo via admin para não deixar lixo
    admin_conn = ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection
    end
    admin_conn.execute("DELETE FROM conversations")
    admin_conn.execute("DELETE FROM municipalities")
  end

  it "sem tenant setado, query de domínio levanta" do
    expect {
      Conversation.count
    }.to raise_error(ActiveRecord::StatementInvalid, /app\.municipality_id/)
  end

  it "com tenant A setado, só vê linha de A" do
    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", @a_id])
      )
      expect(Conversation.count).to eq(1)
      expect(Conversation.first.municipality_id).to eq(@a_id)
    end
  end

  it "com tenant A setado, não pode inserir linha de B (WITH CHECK)" do
    ApplicationRecord.transaction do
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", @a_id])
      )
      expect {
        ApplicationRecord.connection.execute(<<~SQL.squish)
          INSERT INTO conversations (id, municipality_id, phone, state, created_at, updated_at)
          VALUES (gen_random_uuid(), '#{@b_id}', 'mal-intencionado', 'greeting', now(), now())
        SQL
      }.to raise_error(ActiveRecord::StatementInvalid, /row.level security|tenant_isolation/i)
    end
  end

  it "sob bypass (rota_admin), enxerga as duas conversas" do
    admin_conn = ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection
    end
    count = admin_conn.select_value("SELECT count(*) FROM conversations").to_i
    expect(count).to eq(2)
  end
end

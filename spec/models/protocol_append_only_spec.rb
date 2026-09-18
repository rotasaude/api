require "rails_helper"

# As três tabelas são a PROVA de quem editou, assinou e ativou (spec §5): um
# registro que se pode alterar não prova nada. O trigger fecha o caminho que o
# modelo não fecha — um bug, um update_all, um TRUNCATE, um upsert com
# ON CONFLICT DO UPDATE, um psql aberto com o papel de RUNTIME da app. Isto NÃO
# defende contra o DONO das tabelas (o papel de runtime da cidade): o dono
# sempre pode DROP TRIGGER ou DISABLE TRIGGER — ver db/city_triggers.sql.
RSpec.describe "Protocol append-only tables" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:protocol) do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "draft", definition: protocol_definition_hash)
  end
  let(:reviewer) { make_reviewer! }

  def rows
    [
      ProtocolContribution.create!(protocol_definition: protocol, actor_id: reviewer.id, actor_kind: "user",
                                   content_digest: protocol.content_digest),
      ProtocolSignature.create!(protocol_definition: protocol, purpose: "publication", signer: reviewer,
                                content_digest: protocol.content_digest),
      ProtocolActivation.create!(protocol_definition: protocol, kind: "signed", actor_id: reviewer.id,
                                 actor_kind: "user")
    ]
  end

  # Cada tentativa levanta dentro da transação de fixture (use_transactional_fixtures)
  # e deixa a conexão do Postgres em estado abortado até um ROLLBACK — sem isto, a
  # segunda tentativa do each veria "current transaction is aborted", não o erro do
  # trigger. requires_new: true abre um savepoint por tentativa: a exceção original
  # ainda se propaga (AR relança depois do ROLLBACK TO SAVEPOINT), mas só aquele
  # savepoint é desfeito, deixando a transação externa livre para a próxima tentativa.
  #
  # O savepoint tem de ser aberto na conexão CERTA: ActiveRecord::Base.transaction
  # abre na conexão de ActiveRecord::Base (primary/city_unset — banco vazio de
  # propósito, ver README), não na da cidade. connected_to_many (CityConnection.with)
  # só troca role/shard para CityRecord/SolidQueue::Record, nunca para
  # ActiveRecord::Base em si — então esse savepoint não protegeria nada, e a
  # segunda tentativa do each continuaria vendo "current transaction is aborted".
  # row.class (ProtocolContribution etc., que HERDA de CityRecord) abre o
  # savepoint na conexão certa.
  def attempt(klass)
    klass.transaction(requires_new: true) { yield }
  end

  it "refuses UPDATE on every table, even through update_all" do
    rows.each do |row|
      expect { attempt(row.class) { row.class.where(id: row.id).update_all(created_at: 1.day.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end

  it "refuses DELETE on every table, even through delete_all" do
    rows.each do |row|
      expect { attempt(row.class) { row.class.where(id: row.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end

  # TRUNCATE não dispara trigger de LINHA (BEFORE UPDATE OR DELETE ... FOR EACH
  # ROW) — não há OLD/NEW por linha numa operação que esvazia a tabela inteira.
  # Só um trigger de ESTATUTO (FOR EACH STATEMENT ... BEFORE TRUNCATE) o vê;
  # db/city_triggers.sql declara um por tabela.
  it "refuses TRUNCATE on every table" do
    rows.each do |row|
      expect { attempt(row.class) { row.class.connection.execute("TRUNCATE #{row.class.quoted_table_name}") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end

  # ON CONFLICT DO UPDATE dispara o trigger BEFORE UPDATE de linha — é uma
  # atualização, mesmo escrita como um INSERT. A PK (id) é a única constraint
  # única nas três tabelas, então ela é o alvo do conflito: reenviar o mesmo id
  # de uma linha já existente força o caminho DO UPDATE.
  it "refuses upsert_all with an on-conflict update, via the primary key" do
    row = rows.first

    expect {
      attempt(row.class) do
        ProtocolContribution.upsert_all(
          [ { id: row.id, protocol_definition_id: protocol.id, actor_id: reviewer.id, actor_kind: "user",
             content_digest: "outro-digest", created_at: Time.current } ],
          unique_by: :id
        )
      end
    }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "treats a persisted row as read-only in the model too" do
    rows.each { |row| expect(row).to be_readonly }
  end

  it "accepts protocol_reviewer as a membership role, in the model and in the database CHECK" do
    user = User.create!(email_address: "rv-#{SecureRandom.hex(3)}@example.org", password: "secret123")

    expect { Membership.create!(user: user, role: "protocol_reviewer", granted_at: Time.current) }.not_to raise_error
  end

  it "refuses an unknown purpose, kind or actor kind in the database" do
    expect {
      ProtocolSignature.new(protocol_definition: protocol, purpose: "x", signer: reviewer,
                            content_digest: "d").save!(validate: false)
    }.to raise_error(ActiveRecord::StatementInvalid)
  end

  # kind = 'signed' OR length(btrim(reason)) > 0 vale NULL (nem true nem
  # false) quando kind = 'emergency_revert' e reason IS NULL — o Postgres trata
  # CHECK NULL como aprovado, não recusado. Sem o IS NOT NULL explícito, uma
  # reversão de emergência sem motivo passava sempre que o modelo fosse
  # contornado (achado do review). "  " (só espaço) já falhava antes: btrim
  # esvazia a string, length 0.
  it "refuses an emergency_revert with a blank reason in the database, nil or whitespace" do
    # protocol/reviewer FORA do attempt: são `let`, memoizados na PRIMEIRA
    # referência — se essa primeira referência caísse dentro do savepoint da
    # 1ª tentativa (que sempre levanta, de propósito), o ROLLBACK TO SAVEPOINT
    # zeraria o `id` deles em memória (Rails limpa a PK de todo registro criado
    # dentro de uma transação revertida), e a 2ª tentativa gravaria actor_id
    # NULL em vez de reproduzir o mesmo cenário.
    pd, rv = protocol, reviewer

    [ nil, "  " ].each do |reason|
      expect {
        attempt(ProtocolActivation) do
          ProtocolActivation.new(protocol_definition: pd, kind: "emergency_revert", actor_id: rv.id,
                                 actor_kind: "user", reason: reason).save!(validate: false)
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /ck_protocol_activations_revert_reason/)
    end
  end
end

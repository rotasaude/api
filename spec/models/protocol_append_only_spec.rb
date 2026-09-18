require "rails_helper"

# As três tabelas são a PROVA de quem editou, assinou e ativou (spec §5): um
# registro que se pode alterar não prova nada. O trigger fecha o caminho que o
# modelo não fecha — um bug, um update_all, um psql aberto com o papel da app.
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
end

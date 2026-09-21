require "rails_helper"

# Decisão do usuário (fatia 2, opção A): cada versão em uso antes das
# assinaturas ganha uma linha-base, e é ela que torna a PRIMEIRA ativação
# assinada de uma cidade reversível em emergência.
RSpec.describe "Baseline protocol activations" do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  def backfill!
    require Rails.root.join("db/city_migrate/20260921000001_add_baseline_protocol_activations.rb").to_s
    # ProtocolActivation.connection, não ActiveRecord::Base.connection: esta
    # última é a conexão de ActiveRecord::Base em si (primary/city_unset,
    # banco vazio de propósito — ver README e o comentário de
    # spec/models/protocol_append_only_spec.rb#attempt). CityConnection.with
    # (aberta pelo around de TEST_CITY_A) só troca role/shard para
    # CityRecord/SolidQueue::Record, nunca para ActiveRecord::Base.
    ProtocolActivation.connection.execute(AddBaselineProtocolActivations::BACKFILL_SQL)
  end

  let(:legacy) do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", activated_at: 3.days.ago,
                               definition: protocol_definition_hash)
  end

  it "creates one baseline for a version in use with no activation record, dated when it was activated" do
    legacy
    backfill!

    row = legacy.activations.sole
    expect(row).to have_attributes(kind: "baseline", actor_kind: "system", actor_id: nil, reason: nil)
    expect(row.created_at).to be_within(1.second).of(legacy.activated_at)
  end

  it "is idempotent and skips a protocol that already has any activation record" do
    legacy
    backfill!
    backfill!
    ProtocolDefinition.create!(name: "zika", version: 1, status: "active", activated_at: 1.day.ago,
                               definition: protocol_definition_hash(name: "zika"))
                      .activations.create!(kind: "signed", actor_id: SecureRandom.uuid, actor_kind: "user")
    backfill!

    expect(ProtocolActivation.where(kind: "baseline").count).to eq(1)
  end

  it "never creates a baseline for a version that is not in use" do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "published", definition: protocol_definition_hash)
    backfill!

    expect(ProtocolActivation.count).to eq(0)
  end

  # Cada tentativa que viola uma CHECK aborta a transação de fixture e deixa a
  # conexão do Postgres em estado abortado até um ROLLBACK — sem isto, a
  # tentativa seguinte veria "current transaction is aborted", não o erro do
  # CHECK. requires_new: true abre um savepoint por tentativa (mesmo padrão de
  # spec/models/protocol_append_only_spec.rb#attempt): só aquele savepoint é
  # desfeito, deixando a transação externa livre para a próxima tentativa.
  def attempt
    ProtocolActivation.transaction(requires_new: true) { yield }
  end

  it "refuses a baseline with an actor, a non-baseline without an actor, and a system actor on a signed act" do
    # `legacy` é um `let`, memoizado na PRIMEIRA referência — fora de todo
    # `attempt`, para o ROLLBACK TO SAVEPOINT da primeira tentativa não zerar
    # o `id` dela em memória (mesmo cuidado do spec de append-only).
    pd = legacy

    expect {
      attempt do
        pd.activations.new(kind: "baseline", actor_kind: "system", actor_id: SecureRandom.uuid).save!(validate: false)
      end
    }.to raise_error(ActiveRecord::StatementInvalid, /ck_protocol_activations_baseline_has_no_actor/)

    expect {
      attempt do
        pd.activations.new(kind: "signed", actor_kind: "user", actor_id: nil).save!(validate: false)
      end
    }.to raise_error(ActiveRecord::StatementInvalid, /ck_protocol_activations_baseline_has_no_actor/)

    expect {
      attempt do
        pd.activations.new(kind: "signed", actor_kind: "system", actor_id: SecureRandom.uuid).save!(validate: false)
      end
    }.to raise_error(ActiveRecord::StatementInvalid, /ck_protocol_activations_system_is_baseline/)
  end
end

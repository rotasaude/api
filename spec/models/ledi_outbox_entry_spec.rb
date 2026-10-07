require "rails_helper"

# Spec §6.3 e ADR 0028 ("O conteúdo serializado de ficha aceita não existe mais
# na fila"): accepted é imutável e sem payload; payload só vai a nulo; a
# identidade da ficha nunca muda; o uuid só muda no reenvio de uma recusada.
RSpec.describe LediOutboxEntry do
  around { |ex| CityConnection.with(register_test_city!) { ex.run } }

  def entry!(**attrs)
    described_class.create!({ uuid: "1234567-#{SecureRandom.uuid}", ficha_type: "procedimento", competence: "202610",
                              source_type: "synthetic", source_id: SecureRandom.uuid, ledi_version: "8.7.0",
                              next_attempt_at: Time.current, bytes: "\x0B\x01".b }.merge(attrs))
  end

  # Cada statement que deve levantar roda num savepoint: o erro do PG não aborta
  # a transação do exemplo.
  def in_savepoint(&block) = ApplicationRecord.transaction(requires_new: true, &block)

  it "guarda o binário cifrado (Base64 por dentro) e lê de volta" do
    entry = entry!
    raw = described_class.connection.select_value("SELECT payload FROM ledi_outbox WHERE id = #{described_class.connection.quote(entry.id)}")
    expect(raw).not_to include(Base64.strict_encode64("\x0B\x01".b))
    expect(entry.reload.bytes).to eq("\x0B\x01".b)
  end

  it "accepted exige payload nulo e não muda mais; DELETE de accepted é recusado" do
    entry = entry!
    expect { in_savepoint { entry.update_columns(status: "accepted", accepted_at: Time.current) } }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_ledi_outbox_accepted_payload/)
    entry.reload.accept! # update_columns sujou o objeto em memória antes de o banco recusar
    expect(entry.reload.payload).to be_nil
    expect { in_savepoint { entry.update_columns(last_error_codes: [ { "field" => "other", "code" => "unknown" } ]) } }.to raise_error(ActiveRecord::StatementInvalid, /accepted is immutable/)
    expect { in_savepoint { entry.delete } }.to raise_error(ActiveRecord::StatementInvalid, /accepted is immutable/)
  end

  it "payload nulo não volta; identidade não muda; uuid só muda de rejected para pending" do
    entry = entry!
    entry.update_columns(payload: nil)
    expect { in_savepoint { entry.update_columns(payload: "x") } }.to raise_error(ActiveRecord::StatementInvalid, /payload only goes to null/)

    other = entry!
    expect { in_savepoint { other.update_columns(competence: "202611") } }.to raise_error(ActiveRecord::StatementInvalid, /identity/)
    expect { in_savepoint { other.update_columns(uuid: "1234567-x") } }.to raise_error(ActiveRecord::StatementInvalid, /uuid/)
    other.reject!([ { "field" => "cnes", "code" => "invalid" } ])
    other.update!(status: "pending", uuid: "1234567-#{SecureRandom.uuid}")
    expect(other.reload.status).to eq("pending")
  end

  it "CHECKs: status, competência, accepted_at e uuid únicos por fonte" do
    expect { in_savepoint { entry!(status: "lost") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_ledi_outbox_status/)
    expect { in_savepoint { entry!(competence: "202613") } }.to raise_error(ActiveRecord::StatementInvalid, /ck_ledi_outbox_competence/)
    source = SecureRandom.uuid
    entry!(source_id: source)
    expect { in_savepoint { entry!(source_id: source) } }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "claim! marca sending e grava a primeira tentativa; release! devolve sem tocar em attempts" do
    due = entry!(next_attempt_at: 1.minute.ago)
    later = entry!(next_attempt_at: 1.hour.from_now)
    claimed = described_class.claim!(limit: 10)
    expect(claimed.map(&:id)).to eq([ due.id ])
    expect(due.reload.status).to eq("sending")
    expect(due.first_attempt_at).to be_present
    expect(later.reload.status).to eq("pending")

    described_class.release!([ due.id ])
    expect(due.reload.slice(:status, :attempts)).to eq("status" => "pending", "attempts" => 0)
  end

  # R34: devolver sem ter tentado (pausa, ensure, login fora do ar) não abre a
  # janela de 24 h; quem já tentou mantém a primeira tentativa.
  it "release! zera first_attempt_at de quem nunca tentou e mantém o de quem já tentou" do
    fresh = entry!(next_attempt_at: 1.minute.ago)
    tried = entry!(next_attempt_at: 1.minute.ago)
    described_class.claim!(limit: 10)
    first_try = 2.hours.ago.change(usec: 0)
    tried.update_columns(attempts: 1, first_attempt_at: first_try)
    untouched = entry!.tap { |e| e.update_columns(first_attempt_at: first_try) } # pending: release! não toca

    described_class.release!([ fresh.id, tried.id, untouched.id ])
    expect(fresh.reload.slice(:status, :attempts, :first_attempt_at))
      .to eq("status" => "pending", "attempts" => 0, "first_attempt_at" => nil)
    expect(tried.reload.slice(:status, :attempts, :first_attempt_at))
      .to eq("status" => "pending", "attempts" => 1, "first_attempt_at" => first_try)
    expect(untouched.reload.first_attempt_at).to eq(first_try)
  end

  it "release_stale! devolve só o sending parado há mais do limite" do
    stale = entry!.tap { |e| e.update_columns(status: "sending", updated_at: 11.minutes.ago) }
    fresh = entry!.tap { |e| e.update_columns(status: "sending", updated_at: 1.minute.ago) }
    expect(described_class.release_stale!(before: 10.minutes.ago)).to eq(1)
    expect([ stale.reload.status, fresh.reload.status ]).to eq(%w[pending sending])
  end
end

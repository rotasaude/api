require "rails_helper"
require Rails.root.join("db/city_migrate/20261007300002_ledi_outbox_error_codes.rb").to_s

# api#43 (spec §6): a migração converte o texto antigo no que der e zera o
# resto; o texto nunca sobrevive.
RSpec.describe "Migração de cidade 20261007300002 (LediOutboxErrorCodes): conversão do last_error" do
  {
    "Erro de validação; cpfCidadao: CPF [número] inválido" => [ { "field" => "cpfCidadao", "code" => "invalid" } ],
    "Erro de validação; headerTransport.ine: obrigatório; cnes: não pertence ao município" =>
      [ { "field" => "ine", "code" => "required" }, { "field" => "cnes", "code" => "unknown" } ],
    "HTTP 503" => [ { "field" => "transport", "code" => "http_error" } ],
    "PEC inacessível" => [ { "field" => "transport", "code" => "unreachable" } ],
    "endereço do PEC inválido" => [ { "field" => "transport", "code" => "invalid_url" } ],
    "login no PEC respondeu 500" => [ { "field" => "transport", "code" => "login_failed" } ],
    "erro interno (RuntimeError)" => [ { "field" => "transport", "code" => "internal_error" } ],
    "CNES 9999991 não pertence ao município da instalação." => [ { "field" => "other", "code" => "unknown" } ],
    "MARIA DA SILVA nascida em 10/05/1980" => [ { "field" => "other", "code" => "unknown" } ]
  }.each do |text, codes|
    it("#{text.truncate(40)} → #{codes.map { |c| c.values.join('/') }.join(', ')}") do
      expect(LediOutboxErrorCodes.codes_for(text)).to eq(codes)
    end
  end

  it "texto vazio não vira código" do
    expect(LediOutboxErrorCodes.codes_for(nil)).to eq([])
    expect(LediOutboxErrorCodes.codes_for("  ")).to eq([])
  end
end

# A migração sobre linhas reais (tabela antiga, com last_error): o texto nunca
# sobrevive em linha alguma, as constraints novas valem para todo status e o
# guarda segue ligado (a migração não o desliga).
RSpec.describe "Migração de cidade 20261007300002 (LediOutboxErrorCodes): dados existentes" do
  require Rails.root.join("db/city_migrate/20261006200001_create_ledi_outbox.rb").to_s

  around { |ex| CityConnection.with(register_test_city!) { ex.run } }

  def conn = ApplicationRecord.connection
  def quote(value) = conn.quote(value)

  def old_row!(status, last_error:, attempts: 1, payload: "x")
    id = SecureRandom.uuid
    conn.execute(<<~SQL)
      INSERT INTO ledi_outbox (id, uuid, ficha_type, competence, source_type, source_id, ledi_version, status,
                               attempts, last_error, payload, accepted_at, next_attempt_at, created_at, updated_at)
      VALUES (#{quote(id)}, #{quote("1234567-#{SecureRandom.uuid}")}, 'procedimento', '202610', 'synthetic',
              #{quote(SecureRandom.uuid)}, '8.7.0', #{quote(status)}, #{attempts}, #{quote(last_error)},
              #{status == 'accepted' ? 'NULL' : quote(payload)}, #{status == 'accepted' ? 'now()' : 'NULL'},
              now(), now() - interval '3 days', now() - interval '2 days')
    SQL
    id
  end

  it "converte em códigos, zera o resto e o texto antigo some de toda linha" do
    ApplicationRecord.transaction(requires_new: true) do
      ActiveRecord::Migration.suppress_messages do
        CreateLediOutbox.new.exec_migration(conn, :down)
        CreateLediOutbox.new.exec_migration(conn, :up)
      end
      texts = {
        rejected: "Erro de validação; cpfCidadao: CPF [número] inválido; nomeCidadao: MARIA DA SILVA",
        rejected_blank: " ",
        failed: "HTTP 503",
        pending: "PEC inacessível",
        sending: "MARIA DA SILVA nascida em 10/05/1980"
      }
      ids = {
        rejected: old_row!("rejected", last_error: texts[:rejected]),
        rejected_blank: old_row!("rejected", last_error: texts[:rejected_blank]),
        rejected_no_payload: old_row!("rejected", last_error: "x", payload: nil),
        failed: old_row!("failed", last_error: texts[:failed]),
        pending: old_row!("pending", last_error: texts[:pending]),
        sending: old_row!("sending", last_error: texts[:sending]),
        fresh: old_row!("pending", last_error: nil, attempts: 0),
        accepted: old_row!("accepted", last_error: nil),
        accepted_with_text: old_row!("accepted", last_error: "MARIA DA SILVA")
      }

      ActiveRecord::Migration.suppress_messages { LediOutboxErrorCodes.new.exec_migration(conn, :up) }
      LediOutboxEntry.reset_column_information

      expect(conn.column_exists?(:ledi_outbox, :last_error)).to be(false)
      rows = conn.select_all("SELECT * FROM ledi_outbox").to_a.index_by { |r| r["id"] }
      codes = ids.transform_values { |id| JSON.parse(rows.fetch(id)["last_error_codes"]) }
      expect(codes).to eq(
        rejected: [ { "field" => "cpfCidadao", "code" => "invalid" } ],
        rejected_blank: [ { "field" => "other", "code" => "unknown" } ],
        rejected_no_payload: [ { "field" => "other", "code" => "unknown" } ],
        failed: [ { "field" => "transport", "code" => "http_error" } ],
        pending: [ { "field" => "transport", "code" => "unreachable" } ],
        sending: [ { "field" => "other", "code" => "unknown" } ],
        fresh: [], accepted: [], accepted_with_text: []
      )
      expect(codes.values).to all(satisfy { |c| Ledi::ErrorCodes.valid?(c) })
      dump = rows.values.to_json
      expect(dump).not_to include("MARIA", "CPF", "1980", "inacess", "HTTP 503", "Erro de valida")

      # last_attempted_at: updated_at onde houve tentativa; accepted não é tocada.
      attempted = rows.values.reject { |r| r["status"] == "accepted" || r["attempts"].zero? }
      expect(attempted.map { |r| r["last_attempted_at"] }).to eq(attempted.map { |r| r["updated_at"] })
      expect(rows.fetch(ids[:fresh])["last_attempted_at"]).to be_nil
      expect(rows.values_at(ids[:accepted], ids[:accepted_with_text]).map { |r| r["last_attempted_at"] }).to eq([ nil, nil ])

      # O guarda segue ligado: accepted continua imutável.
      expect(conn.select_value("SELECT tgenabled FROM pg_trigger WHERE tgname = 'ledi_outbox_guard'")).to eq("O")
      expect do
        ApplicationRecord.transaction(requires_new: true) do
          conn.execute("UPDATE ledi_outbox SET last_error_codes = '[]'::jsonb WHERE id = #{quote(ids[:accepted])}")
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /accepted is immutable/)
      raise ActiveRecord::Rollback
    end
  ensure
    LediOutboxEntry.reset_column_information
  end
end

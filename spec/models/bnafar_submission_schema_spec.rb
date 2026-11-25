require "rails_helper"
require Rails.root.join("db/city_migrate/20261125900003_add_bnafar_submissions.rb").to_s

# Módulo 27b (Task 10; contrato §3; Q8, Q14, Q25; R10, R11): as tabelas do
# envio diário. O banco segura o formato; os triggers seguram o que o código não
# pode quebrar: nada some, a situação só anda para a frente, o payload só vira
# NULL (ou se re-cifra), o `codigoBnafar` gravado não muda.
RSpec.describe "Esquema do envio à BNAFAR (módulo 27b)", type: :model do
  before { pharmacy_city! }
  let(:central) { central_location! }
  let(:lot) { stocked_lot!(central, item: losartana, quantity: "50") }

  def submission!(**over)
    BnafarSubmission.create!({ reference_on: Time.zone.today - 1, subject: "position", environment: "production" }.merge(over))
  end

  # let!: nunca nasce dentro do savepoint de um `refused` (seria desfeita e ficaria memoizada).
  let!(:default_submission) { submission!(subject: "exit", reference_on: Time.zone.today - 5) }

  def batch!(submission = default_submission, **over)
    BnafarBatch.create!({ bnafar_submission: submission, operation: "post" }.merge(over))
  end

  def record!(submission = default_submission, **over)
    BnafarRecord.create!({ bnafar_submission: submission, origin_code: SecureRandom.uuid, subject: submission.subject,
                           stock_location: central, item_key: "medication:#{losartana.id}", payload: '{"itens":[]}' }.merge(over))
  end

  def accepted!(record, code: 987_654)
    record.update_columns(status: "accepted", accepted_at: Time.current, bnafar_code: code, sent_at: Time.current)
    record
  end

  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "a migração espelha Bnafar::Catalog; irreversível" do
    catalog = Bnafar::Catalog
    expect([ AddBnafarSubmissions::ENVIRONMENTS, AddBnafarSubmissions::SUBJECTS, AddBnafarSubmissions::SUBMISSION_STATUSES,
             AddBnafarSubmissions::BATCH_STATUSES, AddBnafarSubmissions::BATCH_OPERATIONS, AddBnafarSubmissions::RECORD_STATUSES,
             AddBnafarSubmissions::LINK_KINDS ])
      .to eq([ catalog::ENVIRONMENTS, catalog::SUBJECTS, catalog::SUBMISSION_STATUSES, catalog::BATCH_STATUSES, catalog::BATCH_OPERATIONS,
               catalog::RECORD_STATUSES, catalog::LINK_KINDS ])
    expect { AddBnafarSubmissions.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  describe "bnafar_settings" do
    it "linha única, production por padrão; started_on grava uma vez; nunca some" do
      setting = BnafarSetting.current
      expect(setting).to have_attributes(id: 1, environment: "production", started_on: nil)
      refused(/ck_bnafar_settings_singleton/) { BnafarSetting.create!(id: 2, updated_at: Time.current) }
      refused(/ck_bnafar_settings_environment/) { setting.update_columns(environment: "staging") }
      setting.update_columns(environment: "homologation", started_on: Time.zone.today)
      refused(/started_on/) { setting.update_columns(started_on: Time.zone.today - 1) }
      refused(/bnafar_settings/) { setting.delete }
    end
  end

  describe "bnafar_submissions" do
    it "duas remessas do mesmo dia, assunto e ambiente → único; outro ambiente ou assunto passa" do
      submission!
      expect { submission! }.to raise_error(ActiveRecord::RecordNotUnique, /idx_bnafar_submissions_once/)
      expect(submission!(environment: "homologation")).to be_persisted
      expect(submission!(subject: "exit")).to be_persisted
    end

    it "a situação só anda para a frente; dia, assunto e ambiente nunca mudam" do
      row = submission!
      refused(/status building -> processing refused/) { row.update_columns(status: "processing") }
      %w[queued sending processing queued sending].each { |status| row.update_columns(status: status) }
      row.update_columns(status: "finished", finished_at: Time.current)
      refused(/status finished -> sending refused/) { row.update_columns(status: "sending") }
      refused(/never change/) { row.update_columns(reference_on: row.reference_on - 1) }
      refused(/never change/) { row.update_columns(environment: "homologation") }
      row.update_columns(status: "lost")
      refused(/status lost -> queued refused/) { row.update_columns(status: "queued") }
      refused(/bnafar_submissions/) { row.delete }
    end

    it "finished → queued só com uma parte post nova queued (R10); put e delete não reabrem" do
      row = submission!
      first = batch!(row)
      row.update_columns(status: "queued")
      first.update_columns(status: "sending")
      first.update_columns(status: "finished")
      row.update_columns(status: "finished", finished_at: Time.current)
      batch!(row, operation: "put")
      batch!(row, operation: "delete")
      refused(/finished -> queued refused/) { row.update_columns(status: "queued") }
      batch!(row, operation: "post")
      row.update_columns(status: "queued")
      expect(row.reload.status).to eq("queued")
    end

    it "remessa vazia nasce building e fecha finished; tentativas nunca descem; sent_at uma vez" do
      row = submission!
      row.update_columns(status: "finished", finished_at: Time.current)
      other = submission!(subject: "exit")
      other.update_columns(attempts: 2, sent_at: Time.current)
      refused(/attempts never decrease/) { other.update_columns(attempts: 1) }
      refused(/sent_at is recorded once/) { other.update_columns(sent_at: 1.hour.from_now) }
      refused(/ck_bnafar_submissions_finished/) { submission!(environment: "homologation").update_columns(status: "finished") }
    end

    it "last_error só leva código, nunca o texto da BNAFAR" do
      refused(/ck_bnafar_submissions_last_error/) { submission!(last_error: "MSG06 recusado") }
      expect(submission!(last_error: "MSG06")).to be_persisted
    end
  end

  describe "bnafar_batches" do
    it "evidência em remessa de produção → trigger; em homologação passa" do
      refused(/evidence only in homologation/) { batch!(evidence: [ { "curl" => "curl -X POST" } ]) }
      production = batch!
      refused(/evidence only in homologation/) { production.update_columns(evidence: [ { "curl" => "curl -X POST" } ]) }
      homologation = batch!(submission!(environment: "homologation"), evidence: [ { "curl" => "curl -X POST" } ])
      expect(homologation.reload.evidence).to eq([ { "curl" => "curl -X POST" } ])
    end

    it "operação post|put|delete; situação só para a frente; protocolo grava uma vez; nunca some" do
      refused(/ck_bnafar_batches_operation/) { batch!(operation: "patch") }
      row = batch!
      refused(/status queued -> processing refused/) { row.update_columns(status: "processing") }
      row.update_columns(status: "sending")
      row.update_columns(status: "queued", attempts: 1)
      row.update_columns(status: "sending", attempts: 2)
      row.update_columns(status: "processing", protocol: 1_234_567, sent_at: Time.current)
      refused(/protocol is recorded once/) { row.update_columns(protocol: 7_654_321) }
      row.update_columns(status: "finished", finished_at: Time.current)
      refused(/status finished -> queued refused/) { row.update_columns(status: "queued") }
      refused(/never change/) { row.update_columns(operation: "put") }
      refused(/bnafar_batches/) { row.delete }
    end
  end

  describe "bnafar_records" do
    it "origin_code único; payload cifrado" do
      code = SecureRandom.uuid
      record!(origin_code: code)
      expect { record!(origin_code: code) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_bnafar_records_origin_code/)
      raw = ApplicationRecord.connection.select_value("SELECT payload FROM bnafar_records WHERE origin_code = '#{code}'")
      expect(raw).not_to include("itens")
      expect(BnafarRecord.find_by(origin_code: code).payload).to eq('{"itens":[]}')
    end

    it "payload → NULL passa; trocado → trigger; re-cifra sob a marca passa" do
      row = record!
      CityEncryption.allowing_reencryption { row.encrypt }
      refused(/payload only becomes NULL/) { row.update_columns(payload: '{"itens":[1]}') }
      row.update_columns(payload: nil)
      refused(/payload only becomes NULL/) { row.update_columns(payload: '{"itens":[]}') }
    end

    it "`bnafar_code` gravado não muda; só em registro aceito" do
      row = record!
      refused(/ck_bnafar_records_code/) { row.update_columns(bnafar_code: 1) }
      accepted!(row)
      refused(/bnafar_code never changes/) { row.update_columns(bnafar_code: 111) }
      refused(/bnafar_code never changes/) { row.update_columns(bnafar_code: nil) }
    end

    it "situação só para a frente; rejected → accepted ou accepted → pending → trigger" do
      row = record!
      row.update_columns(status: "rejected", error_codes: [ "MSG09" ])
      refused(/status rejected -> accepted refused/) { row.update_columns(status: "accepted", accepted_at: Time.current) }
      other = accepted!(record!)
      refused(/status accepted -> pending refused/) { other.update_columns(status: "pending", accepted_at: nil, bnafar_code: nil) }
      refused(/change only with the status/) { other.update_columns(rejected_items: 3) }
    end

    it "rejected → pending troca payload, parte e códigos juntos (R11); fora do reenvio, trocar a parte → trigger" do
      submission = submission!
      first = batch!(submission)
      row = record!(submission, bnafar_batch: first)
      row.update_columns(status: "rejected", error_codes: [ "MSG12" ], sent_at: Time.current)
      second = batch!(submission)
      row.update_columns(status: "pending", payload: '{"itens":["novo"]}', bnafar_batch_id: second.id, error_codes: [])
      expect(row.reload).to have_attributes(status: "pending", bnafar_batch_id: second.id, error_codes: [], payload: '{"itens":["novo"]}')
      refused(/bnafar_batch_id is set once/) { row.update_columns(bnafar_batch_id: first.id) }
      refused(/sent_at, accepted_at and deletion_batch_id are recorded once/) { row.update_columns(sent_at: 1.hour.from_now) }
    end

    it "`deleted_at` em registro rejeitado → trigger; no aceito, uma vez, pela parte delete" do
      submission = submission!
      rejected = record!(submission)
      rejected.update_columns(status: "rejected", error_codes: [ "MSG09" ])
      deletion = batch!(submission, operation: "delete")
      refused(/deleted_at is recorded once, only on an accepted record/) do
        rejected.update_columns(deleted_at: Time.current, deletion_batch_id: deletion.id)
      end
      row = accepted!(record!(submission))
      refused(/ck_bnafar_records_deleted_by_batch/) { row.update_columns(deleted_at: Time.current) }
      row.update_columns(deletion_batch_id: deletion.id)
      row.update_columns(deleted_at: Time.current)
      refused(/deleted_at is recorded once/) { row.update_columns(deleted_at: 1.hour.from_now) }
    end

    it "error_codes só levam códigos MSG, nunca o texto" do
      row = record!
      refused(/ck_bnafar_records_error_codes/) { row.update_columns(status: "rejected", error_codes: [ "O lote informado não existe" ]) }
      row.update_columns(status: "rejected", error_codes: %w[MSG09 MSG12])
      expect(row.reload.error_codes).to eq(%w[MSG09 MSG12])
    end

    it "inspect, to_s e as_json nunca mostram o payload" do
      row = record!
      expect([ row.inspect, row.to_s, row.as_json.to_s ].join).not_to include("itens")
    end
  end

  describe "bnafar_movement_links" do
    it "movimento ligado duas vezes → único; o link nunca muda nem some" do
      movement = StockMovement.find_by!(stock_lot_id: lot.id)
      record = record!
      link = BnafarMovementLink.create!(stock_movement: movement, bnafar_record: record, kind: "exit")
      expect { BnafarMovementLink.create!(stock_movement: movement, bnafar_record: record!, kind: "exit") }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_bnafar_movement_links_movement/)
      refused(/ck_bnafar_movement_links_kind/) { BnafarMovementLink.create!(stock_movement: movement, bnafar_record: record, kind: "other") }
      refused(/append-only/) { link.update_columns(kind: "deletion") }
      refused(/append-only/) { link.delete }
    end
  end

  it "TRUNCATE recusado nas cinco tabelas" do
    %w[bnafar_settings bnafar_submissions bnafar_batches bnafar_records bnafar_movement_links].each do |table|
      refused(/append-only: TRUNCATE refused/) { ApplicationRecord.connection.execute("TRUNCATE #{table} CASCADE") }
    end
  end
end

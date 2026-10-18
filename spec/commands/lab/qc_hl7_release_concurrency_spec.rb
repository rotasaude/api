require "rails_helper"

# Task 10 (C-E23): o controle pela HL7 e a liberação de um item do mesmo
# aparelho ao mesmo tempo, nas duas ordens. A HL7 trava aparelho (FOR UPDATE)
# → corrida → lote antes de qualquer requisição; a liberação trava o aparelho
# FOR SHARE antes da requisição. Sem deadlock e sem buraco: ou o item não sai
# (qc_blocked), ou sai e entra na revisão do bloqueio que a HL7 abriu.
RSpec.describe "Controle pela HL7 × liberação sob disputa" do
  include LabQcHelpers

  self.use_transactional_tests = false

  let(:release_gate) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |t| %w[schema_migrations ar_internal_metadata].include?(t) }
              .select { |t| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(t)})") }
  end

  before do
    allow(ClinicalTerms::SigtapExams).to receive(:find).and_return(Struct.new(:competence).new(Time.zone.today.strftime("%Y%m")))
    allow(Lab::Gate).to receive(:qc_usable?).and_return(true)
    @rows = in_city do
      @empty = empty_tables
      provider = lab_provider!
      lead = lab_releaser!(provider, lead: true)
      scenario = qc_scenario!(provider: provider)
      staff = lab_staff!
      qc_value!(scenario, "Nível 1", 0.1, by: staff, now: 2.minutes.ago)
      qc_value!(scenario, "Nível 2", 0.2, by: staff, now: 2.minutes.ago + 1)
      Lab::Qc::OpenRun.call(instrument: scenario.instrument, by: staff, now: 1.minute.ago)
      req = received_requisition!(provider: provider, exams: [ scenario.exam ])
      item = type!(req.items.first, { glicose: "98" }, by: staff)
      middleware_token!(provider)
      { req_id: req.id, item_id: item.id, lead: lead.id, token_id: LabMiddlewareToken.where(exam_provider_id: provider.id).sole.id,
        barcode: scenario.lot.level_barcodes.fetch("Nível 1") }
    end
  end

  after do
    3.times { release_gate << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError, ScriptError # join relança o erro da thread; a limpeza abaixo tem de rodar sempre
      nil
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        @empty.to_a.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
      end
    end
  end

  def release
    user = User.find(@rows[:lead])
    Lab::Release.call(requisition: LabRequisition.find(@rows[:req_id]), item_ids: [ @rows[:item_id] ], signature: "advanced",
                      totp: ROTP::TOTP.new(user.otp_secret).now, by: user)
  end

  # Nível 1: média 100, dp 5 → 118 = z 3,6 (1_3s): reprova e abre o bloqueio.
  def hl7_reject
    raw = [ "MSH|^~\\&|MW|LAB|ROTA-SAUDE|t|20261018073000||OUL^R22^OUL_R22|C#{SecureRandom.hex(4)}|P|2.5.1",
            "SPM|1|#{@rows[:barcode]}|||||||||Q", "OBR|1|||GLI^GLI^99RSL",
            "OBX|1|NM|glicose^G^99RSL||118|mg/dL^^UCUM|||||F|||20261018072500||||BIO-01" ].join("\r") + "\r"
    reply = Lab::Hl7::Inbound.call(raw: raw, token: LabMiddlewareToken.find(@rows[:token_id]), city_slug: TEST_CITY_A.slug,
                                   fake_allowed: false, qc_allowed: true)
    reply.split("\r").find { |s| s.start_with?("MSA|") }.split("|")[1]
  end

  # A primeira segura a transação aberta até o release_gate; a segunda espera a trava.
  def race(first, second)
    holding = Queue.new
    first_out = Queue.new
    threads << Thread.new do
      in_city do
        ApplicationRecord.transaction do
          first_out << first.call
          holding << true
          release_gate.pop(timeout: 10) or raise "timeout"
        end
      end
    end
    holding.pop(timeout: 10) or raise "timeout"
    second_out = Queue.new
    threads << Thread.new { in_city { second_out << second.call } }
    sleep 0.3
    release_gate << true
    [ first_out.pop(timeout: 10), second_out.pop(timeout: 10) ]
  end

  it "HL7 primeiro: a liberação espera o aparelho e leva qc_blocked" do
    first, second = race(-> { hl7_reject }, -> { release })
    expect(first).to eq("AA")
    expect(second.reason).to eq(:qc_blocked)
    in_city do
      expect(LabQcBlock.active.count).to eq(1)
      expect(LabRequisitionItem.find(@rows[:item_id]).status).to eq("typed")
      expect(LabReportItem.where(lab_requisition_item_id: @rows[:item_id])).to be_empty
    end
  end

  it "liberação primeiro: a HL7 espera, o item sai e entra na revisão do bloqueio" do
    first, second = race(-> { release }, -> { hl7_reject })
    expect(first).to be_ok
    expect(second).to eq("AA")
    in_city do
      block = LabQcBlock.active.sole
      expect(LabRequisitionItem.find(@rows[:item_id]).status).to eq("released")
      expect(LabQcReviewItem.where(lab_qc_block: block).pluck(:lab_requisition_item_id)).to eq([ @rows[:item_id] ])
      expect(LabQcValue.where(source: "hl7").sole.lab_hl7_receipt_id).to be_present
    end
  end
end

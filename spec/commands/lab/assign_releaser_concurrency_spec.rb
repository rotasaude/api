require "rails_helper"

# Revisão final, I1/L6: encerrar o liberador (end!) × a finalização do laudo.
# Ordem única de trava: requisição → ... → liberador. O end! trava as
# requisições dos laudos ICP pendentes ANTES da linha do liberador; na ordem
# antiga (liberador → requisição) a liberação avançada do mesmo liberador na
# mesma requisição fechava um ciclo e uma das duas levava
# PG::TRDeadlockDetected (500).
RSpec.describe "Encerrar liberador sob disputa" do
  self.use_transactional_tests = false

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |t| %w[schema_migrations ar_internal_metadata].include?(t) }
              .select { |t| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(t)})") }
  end

  let(:threads) { [] }

  before do
    allow(ClinicalTerms::SigtapExams).to receive(:find).and_return(Struct.new(:competence).new(Time.zone.today.strftime("%Y%m")))
    allow(Lab::Release).to receive(:icp_available?).and_return(true)
    @rows = in_city do
      @empty = empty_tables
      provider = lab_provider!
      lead = lab_releaser!(provider, lead: true) # CRBM: ICP e avançada
      lead.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF)
      linked_certificate!(lead, provider: "simulated", leaf: fake_psc("simulated").leaf(SignatureHelpers::DOCTOR_CPF))
      glucose = lab_exam!(provider: provider)
      lipids = lab_exam!(provider: provider, sigtap_code: "0202010295", name: "Perfil lipídico", analytes: LabHelpers::LIPIDS,
                         material: "Soro", container: "Tubo amarelo (gel)", instrument_test_code: "LIP")
      req = received_requisition!(provider: provider, exams: [ glucose, lipids ])
      items = req.items.includes(lab_exam_version: :lab_exam).to_a
      icp_item = items.find { |i| i.lab_exam_version.lab_exam.sigtap_code == glucose.sigtap_code }
      adv_item = items.find { |i| i.id != icp_item.id }
      type!(icp_item, { glicose: "98" })
      type!(adv_item, { ct: "180", hdl: "50", tg: "100" })
      pending = Lab::Release.call(requisition: req, item_ids: [ icp_item.id ], signature: "icp", totp: nil, by: lead)
      raise "ICP não abriu: #{pending.reason}" if pending.failure?

      { req_id: req.id, adv_item: adv_item.id, lead: lead.id, releaser_id: LabReleaser.find_by!(user_id: lead.id).id,
        report_id: pending.payload[:report].id }
    end
  end

  after do
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError
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

  def thread(&block)
    out = Queue.new
    threads << Thread.new do
      in_city { out << block.call }
    rescue StandardError => e
      out << e
    end
    out
  end

  it "end! × liberação avançada do mesmo liberador na mesma requisição: sem deadlock; os dois terminam" do
    holding = Queue.new
    release_out = thread do
      ApplicationRecord.transaction do
        req = LabRequisition.find(@rows[:req_id])
        req.lock! # a ordem do FinalizeReport: requisição primeiro...
        holding << true
        sleep 1.5 # ...e o end! chega e espera; só então o liberador (FOR SHARE)
        user = User.find(@rows[:lead])
        Lab::Release.call(requisition: req, item_ids: [ @rows[:adv_item] ], signature: "advanced",
                          totp: ROTP::TOTP.new(user.otp_secret).now, by: user)
      end
    end
    holding.pop(timeout: 10) or raise "timeout"
    end_out = thread do
      Lab::AssignReleaser.end!(releaser: LabReleaser.find(@rows[:releaser_id]), by: User.find(@rows[:lead]))
    end
    released = release_out.pop(timeout: 20)
    ended = end_out.pop(timeout: 20)
    expect(released).not_to be_a(Exception), released.inspect
    expect(ended).not_to be_a(Exception), ended.inspect
    expect(released).to be_ok
    expect(ended).to be_ok
    in_city do
      expect(LabReleaser.find(@rows[:releaser_id]).ended_at).to be_present
      expect(LabReport.find(@rows[:report_id]).status).to eq("withdrawn")
    end
  end

  # L6: o segundo encerramento simultâneo relê o liberador sob a trava e não
  # sobrescreve ended_at/ended_by nem publica o evento de novo.
  it "dois end! simultâneos: um encerramento, um evento, ended_at do primeiro" do
    gate = Queue.new
    first = thread do
      ApplicationRecord.transaction do
        result = Lab::AssignReleaser.end!(releaser: LabReleaser.find(@rows[:releaser_id]), by: User.find(@rows[:lead]), now: 2.days.ago)
        gate.pop(timeout: 10) or raise "timeout"
        result
      end
    end
    sleep 0.5
    second = thread { Lab::AssignReleaser.end!(releaser: LabReleaser.find(@rows[:releaser_id]), by: User.find(@rows[:lead]), now: Time.current) }
    sleep 0.5
    gate << true
    expect(first.pop(timeout: 20)).to be_ok
    expect(second.pop(timeout: 20)).to be_ok
    in_city do
      expect(LabReleaser.find(@rows[:releaser_id]).ended_at).to be_within(1.minute).of(2.days.ago)
      expect(DomainEvent.where(name: "lab_releaser.ended").count).to eq(1)
    end
  end
end

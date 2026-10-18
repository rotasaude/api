require "rails_helper"

# Desvio 8 (spec §5.6): na abertura do bloqueio entram na revisão os itens do
# aparelho cujo exame (versão) tem o analito e cujo laudo saiu depois da última
# corrida aceita (aprovada ou com aviso) com o analito no aparelho; sem ela,
# depois da primeira referência aceita do analito no aparelho. Chamado direto,
# com um bloqueio montado à mão.
RSpec.describe Lab::Qc::Reviews do
  include ActiveSupport::Testing::TimeHelpers

  before do
    travel_to(Time.zone.now.change(hour: 12))
    qc_city!
  end

  after { travel_back }

  let(:s) { qc_scenario! }
  let(:lead) { lab_releaser!(s.provider, lead: true) }
  let(:staff) { lab_staff! }

  def creatinine = LabHelpers::GLUCOSE.first.merge("key" => "creatinina", "name" => "Creatinina", "decimals" => 2, "entry_min" => nil,
                                                    "entry_max" => nil, "critical_low" => nil, "critical_high" => nil)

  # Laudo liberado agora (31 s depois do anterior: TOTP novo).
  def released!(exam = s.exam, values = { glicose: "98" }, exception_for: nil)
    req = received_requisition!(provider: s.provider, exams: [ exam ])
    item = type!(req.items.first, values)
    Lab::Qc::GrantException.call(block_id: exception_for.id, item_id: item.id, justification: "Urgência", by: lead) if exception_for
    travel 31.seconds
    result = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: ROTP::TOTP.new(lead.reload.otp_secret).now, by: lead)
    raise "liberação recusada: #{result.reason}" if result.failure?

    item
  end

  def accepted_run!(z1 = 0.1, z2 = 0.2)
    travel 1.second
    qc_value!(s, "Nível 1", z1, by: staff)
    travel 1.second
    qc_value!(s, "Nível 2", z2, by: staff)[:run]
  end

  # Corrida reprovada e bloqueio gravados à mão: só o enqueue! roda.
  def block!(instrument: s.instrument, analyte_key: "glicose")
    travel 1.second
    run = LabQcRun.create!(lab_instrument: instrument, sector: instrument.sector, status: "rejected", started_at: Time.current,
                           evaluated_at: Time.current, opened_by_user: staff)
    [ LabQcBlock.create!(lab_instrument: instrument, analyte_key: analyte_key, opened_by_run: run, opened_at: Time.current), run ]
  end

  def queued(block) = LabQcReviewItem.where(lab_qc_block: block).order(:lab_requisition_item_id).pluck(:lab_requisition_item_id, :decision)

  it "desde a última corrida aceita com o analito: o anterior a ela fica de fora; exame sem o analito e outro aparelho também" do
    before_run = released!
    accepted_run!
    after_run = released!
    no_analyte = qc_exam!(provider: s.provider, instrument: s.instrument, sigtap_code: "0202010317", name: "Creatinina",
                          analytes: [ creatinine ], instrument_test_code: "CRE")
    released!(no_analyte, { creatinina: "0,9" })

    block, run = block!
    expect(described_class.enqueue!(block, run: run)).to eq(1)
    expect(queued(block)).to eq([ [ after_run.id, "pending" ] ])
    expect(queued(block).map(&:first)).not_to include(before_run.id)

    other = qc_instrument!(s.provider, name: "Analisador bioquímico 2", hl7_equipment_id: "BIO-02")
    other_block, other_run = block!(instrument: other)
    expect(described_class.enqueue!(other_block, run: other_run)).to eq(0)
  end

  it "corrida com aviso conta como aceita; a reprovada com o analito, não" do
    first = released!
    warning = accepted_run!(2.5, 0.1)
    expect(warning.reload.status).to eq("warning")
    second = released!
    travel 1.second
    Lab::Qc::OpenRun.call(instrument: s.instrument, by: staff) # senão o valor cai na corrida com aviso e a reprova
    travel 1.second
    old_block = qc_value!(s, "Nível 1", 3.6, by: staff)[:block] # corrida reprovada COM glicose; o open! já enfileira
    expect(queued(old_block)).to eq([ [ second.id, "pending" ] ])
    third = released!(exception_for: old_block)

    # Fecha à mão (sem corrida aceita nova, que moveria o "desde").
    Lab::Qc::RecordCorrectiveAction.call(block: old_block, text: "Calibração refeita", by: lead)
    old_block.reload.update!(closed_by_run: old_block.opened_by_run, closed_by_user: lead, closed_at: Time.current)
    block, run = block!
    described_class.enqueue!(block, run: run)
    expect(queued(block).map(&:first)).to match_array([ second.id, third.id ])
    expect(queued(block).map(&:first)).not_to include(first.id)
  end

  it "sem corrida aceita anterior: desde a primeira referência aceita do analito no aparelho" do
    s # referência aceita 30 dias atrás
    old = travel_to(40.days.ago) { released! }
    recent = released!
    block, run = block!
    expect(described_class.enqueue!(block, run: run)).to eq(1)
    expect(queued(block)).to eq([ [ recent.id, "pending" ] ])
    expect(queued(block).map(&:first)).not_to include(old.id)
  end

  it "C-E21: o marco é o início da corrida aceita — o liberado entre os valores dela entra na revisão" do
    travel_to(Time.zone.now.change(hour: 8))
    qc_value!(s, "Nível 1", 0.1, by: staff)
    travel_to(Time.zone.now.change(hour: 9))
    between = released!
    travel_to(Time.zone.now.change(hour: 10))
    accepted = qc_value!(s, "Nível 2", 0.2, by: staff)[:run]
    expect(accepted.reload).to have_attributes(status: "approved", started_at: Time.zone.now.change(hour: 8))
    travel_to(Time.zone.now.change(hour: 11))
    Lab::Qc::OpenRun.call(instrument: s.instrument, by: staff)
    block = qc_value!(s, "Nível 1", 3.6, by: staff)[:block]
    expect(queued(block)).to eq([ [ between.id, "pending" ] ])
  end

  it "laudo ICP pendente de assinatura antes do bloqueio entra na revisão; assinado depois, a revisão continua nele" do
    stub_psc_mock!(City.find(Current.city.id))
    stub_signer!
    lead
    doctor = lab_releaser!(s.provider, council: "CRM").tap { |u| u.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) }
    linked_certificate!(doctor, provider: "simulated", leaf: fake_psc("simulated").leaf(doctor.professional.cpf))
    accepted_run!
    req = received_requisition!(provider: s.provider, exams: [ s.exam ])
    item = type!(req.items.first, { glicose: "98" })
    travel 1.second
    report = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "icp", totp: nil, by: doctor).payload.fetch(:report)
    expect(report.status).to eq("pending_signature")

    travel 1.second
    Lab::Qc::OpenRun.call(instrument: s.instrument, by: staff)
    block = qc_value!(s, "Nível 1", 3.6, by: staff)[:block]
    expect(queued(block)).to eq([ [ item.id, "pending" ] ])

    sign_document!(report, author: doctor, provider: "simulated") # a finalização do ICP não consulta o CIQ
    expect(report.reload.status).to eq("released")
    expect(queued(block)).to eq([ [ item.id, "pending" ] ])
  end
end

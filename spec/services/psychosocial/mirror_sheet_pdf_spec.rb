require "rails_helper"

# Módulo 31 (contrato §6, P14; plano, Desvio 10): a ficha espelho da RAAS tem
# uma página por registro, os blocos na ordem do aplicativo RAAS
# (Identificação, Dados do atendimento, Ações), "PRÉVIA" só com o mês aberto,
# o CID principal e as datas das ações RAAS — e nunca a evolução (notes), o
# PTS, o texto do matriciamento nem as ações BPA.
RSpec.describe Psychosocial::MirrorSheetPdf, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps!(modality: "caps_ii") }
  let(:lead) { caps_staff!(caps, cbo: "223505", lead: true) }
  let(:month) { Date.new(2026, 11, 1) }

  # Matrícula com paciente de nome único (o paciente de teste nasce sempre com o mesmo nome).
  def named_enrollment!(**attrs)
    enrollment!(caps, **attrs).tap { |e| e.patient.update!(full_name: "Paciente #{SecureRandom.alphanumeric(8)} Teste") }
  end

  def text_of(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ").gsub(/\s+/, " ")
  def pages_of(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map { |page| page.text.gsub(/\s+/, " ") }
  def entries = Psychosocial::RaasRecords.for(unit: caps, month: month)

  # Matrícula com duas ações RAAS (uma com evolução), uma ação BPA-C de
  # matriciamento com caso compartilhado e um PTS.
  def busy_enrollment!
    e = named_enrollment!(started_on: month, cid: "F321")
    complete_month!(e, month, by: lead)
    record_action!(caps, lead, performed_at: Time.zone.local(2026, 11, 5, 9), notes: "Evolução sigilosa do atendimento",
                               participants: [ { enrollment_id: e.id } ])
    matrix = record_action!(caps, lead, sigtap_code: "0301080305", performed_at: Time.zone.local(2026, 11, 6, 9),
                                        participants: [ { enrollment_id: e.id } ])
    support = PsychosocialMatrixSupport.create!(health_unit: caps, health_team: registry_team!, held_on: Date.new(2026, 11, 6),
                                                topic: "Tema sigiloso do matriciamento", participant_user_ids: [ lead.id ],
                                                psychosocial_action: matrix, recorded_by_user: lead, sigtap_code: "0301080305")
    PsychosocialMatrixCase.create!(psychosocial_matrix_support: support, patient: e.patient, created_by_user: lead,
                                   shared_text: "Texto compartilhado sigiloso com a UBS")
    PsychosocialCarePlan.create!(psychosocial_enrollment: e, version: 1, needs: "Necessidades sigilosas do PTS", goals: [],
                                 intensity: "intensive", review_on: Date.current + 60, created_by_user: lead)
    e
  end

  it "uma página por registro: Identificação, Dados do atendimento e Ações nessa ordem, com CID e datas, sem texto clínico" do
    e = busy_enrollment!
    second = named_enrollment!(started_on: month)
    complete_month!(second, month, by: lead)

    bytes = described_class.call(records: entries, preview: false, unit: caps, month: month)
    pages = pages_of(bytes)
    expect(pages.size).to eq(2)

    page = pages.find { |p| p.include?(e.patient.full_name) }
    positions = [ "Identificação", "Dados do atendimento", "Ações" ].map { |title| page.index(title) }
    expect(positions).to all(be_present)
    expect(positions).to eq(positions.sort)
    expect(page).to include("F321", e.patient.cns, "05/11/2026", "18/11/2026", "0301080208", caps.cnes)
    expect(page).not_to include("PRÉVIA")
    expect(page).not_to include("0301080305") # BPA-C vai pelo 22, não pela RAAS
    expect(page).not_to include(second.patient.full_name)

    text = text_of(bytes)
    [ "Evolução sigilosa", "Necessidades sigilosas", "Tema sigiloso", "Texto compartilhado sigiloso", e.patient.cpf ].compact.each do |secret|
      expect(text).not_to include(secret)
    end
  end

  it "PRÉVIA no topo de cada página só com o mês aberto" do
    complete_month!(named_enrollment!(started_on: month), month, by: lead)
    complete_month!(named_enrollment!(started_on: month), month, by: lead)

    preview = pages_of(described_class.call(records: entries, preview: true, unit: caps, month: month))
    expect(preview.size).to eq(2)
    expect(preview).to all(include("PRÉVIA"))
    expect(text_of(described_class.call(records: entries, preview: false, unit: caps, month: month))).not_to include("PRÉVIA")
  end

  it "fix round 1: registro que transborda a página — a continuação repete nome, CNS mascarado e o bloco" do
    e = named_enrollment!(started_on: month)
    complete_month!(e, month, by: lead)
    entry = entries.sole
    many = Psychosocial::RaasRecords::Entry.new(record: entry.record, data: entry.data, actions: entry.actions * 60)
    other = named_enrollment!(started_on: month)
    complete_month!(other, month, by: lead)
    second = entries.find { |item| item.record.psychosocial_enrollment_id == other.id }

    pages = pages_of(described_class.call(records: [ many, second ], preview: true, unit: caps, month: month))
    expect(pages.size).to be > 2
    continued = pages[1..-2]
    expect(continued).to all(include("Ações (continuação)", e.patient.full_name, e.patient.cns_masked, "PRÉVIA"))
    continued.each { |page| expect(page).not_to include(e.patient.cns) }
    expect(pages.last).to include(other.patient.full_name, "Identificação")
    expect(pages.last).not_to include("continuação")
  end

  it "sem registro com ação RAAS: uma página que diz isso" do
    named_enrollment!(started_on: month)
    expect(entries).to eq([])
    text = text_of(described_class.call(records: [], preview: true, unit: caps, month: month))
    expect(text).to include("Nenhum registro com ação RAAS no mês", "PRÉVIA")
  end
end

require "rails_helper"

# ADR 0035 (spec §4, §9): consulta só finalizada e só da pessoa com paciente;
# documentos com PDF e código para o cidadão; o registro da Notificação sem
# número para o cidadão; campanha com convite e leitura. Nunca SOAP, CID sem
# nome nem número de talão/SNCR na visão do cidadão.
RSpec.describe "Fornecedores clínicos da linha do tempo" do
  before do
    timeline_city!(documents: true)
    ciap2_release!; cid10_release!; sigtap_release!
  end

  let(:unit) { create_unit("UBS Centro") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(61) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen) }
  let(:person) { Timeline::Person.for_cpf(citizen.cpf) }

  def entries(source) = source.entries(person: person, before: nil, limit: 50, from: nil, to: nil)

  it "consultation: problemas avaliados com nome, condutas e adendos; cidadão vê 'consulta com <profissional>'" do
    consultation
    entry = entries(Timeline::Sources::ConsultationSource).sole
    expect([ entry.source_id, entry.occurred_at ]).to eq([ consultation.id, consultation.finalized_at ])
    expect(entry.summary).to include("T90 Diabetes não insulino-dependente", "condutas: 1", "adendos: 0")
    expect(entry.professional).to eq(name: doctor.professional.professional_name, cbo_code: consultation.cbo_code)
    expect(entry.citizen).to eq(title: "Consulta com #{doctor.professional.professional_name}", summary: nil, status: nil,
                                professional_name: doctor.professional.professional_name)
    expect(entry.to_h.to_s).not_to include("Refere sede", "Metformina")
  end

  it "consultation: rascunho não entra; pessoa sem paciente não tem consulta" do
    started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    expect(entries(Timeline::Sources::ConsultationSource)).to be_empty
    expect(Timeline::Sources::ConsultationSource.entries(person: Timeline::Person.for_cpf(verified_citizen!(62).cpf),
                                                         before: nil, limit: 50, from: nil, to: nil)).to eq([])
  end

  it "clinical_document: tipo, modo e situação; bloco do documento para o cidadão" do
    document = raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "paper")
    entry = entries(Timeline::Sources::ClinicalDocumentSource).sole
    expect([ entry.title, entry.summary, entry.status ]).to eq([ "Atestado", "Papel · Emitido", "issued" ])
    expect(entry.document).to eq(id: document.id, short_code: document.short_code,
                                 verification_url: document.verification_url, downloadable: true)
    expect(entry.citizen).to include(title: "Atestado", status: "issued")
    document.update_columns(status: "cancelled", cancelled_at: Time.current, cancel_reason: "emitido por engano",
                            cancelled_by_user_id: doctor.id)
    expect(entries(Timeline::Sources::ClinicalDocumentSource).sole.document[:downloadable]).to be(false)
  end

  it "clinical_document digital sem assinatura não é baixável" do
    raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "digital")
    expect(entries(Timeline::Sources::ClinicalDocumentSource).sole.document[:downloadable]).to be(false)
  end

  it "controlled_notification: profissional vê tipo, item e talão; cidadão não vê o talão" do
    content = { "notification_type" => "B", "paper_number" => "PR-1234567", "numbering_uf" => "PR",
                "item" => { "printed_description" => "DIAZEPAM 10 mg COMPRIMIDO" } }
    raw_document!(consultation: consultation, kind: "controlled_notification_record", issue_mode: "paper", content: content)
    entry = entries(Timeline::Sources::ControlledNotificationSource).sole
    expect(entry.title).to eq("Notificação de receita B (papel)")
    expect(entry.summary).to eq("DIAZEPAM 10 mg COMPRIMIDO · talão PR-1234567")
    expect(entry.citizen).to eq(title: "Receita de controle especial (talão)", summary: nil, status: "issued",
                                professional_name: doctor.professional.professional_name)
    expect(entry.document).to be_nil
    expect(entries(Timeline::Sources::ClinicalDocumentSource)).to be_empty
  end

  it "campaign: convite e leitura do aviso" do
    campaign = sent_campaign!(title: "Vacinação contra a gripe")
    recipient = recipient!(campaign, citizen)
    entry = entries(Timeline::Sources::CampaignSource).sole
    expect([ entry.title, entry.summary, entry.status ]).to eq([ "Campanha — Vacinação contra a gripe", "Aviso não lido", "unread" ])
    recipient.update_columns(notice_read_at: Time.zone.parse("2026-10-01 09:00"))
    expect(entries(Timeline::Sources::CampaignSource).sole.citizen).to include(summary: "Aviso lido em 01/10/2026", status: "read")
  end

  it "nunca vaza conteúdo do documento, talão, item nem SOAP na visão do cidadão" do
    raw_document!(consultation: consultation, kind: "sick_note", issue_mode: "paper",
                  content: { "type" => "leave", "days" => 3, "note" => "CONTEUDO-SECRETO-ATESTADO" })
    notification = { "notification_type" => "B", "paper_number" => "PR-7654321", "numbering_uf" => "PR",
                     "item" => { "printed_description" => "CLONAZEPAM 2 mg" } }
    raw_document!(consultation: consultation, kind: "controlled_notification_record", issue_mode: "paper", content: notification)
    campaign = recipient!(sent_campaign!(title: "Vacinação contra a gripe"), citizen)
    entries = [ Timeline::Sources::ConsultationSource, Timeline::Sources::ClinicalDocumentSource,
                Timeline::Sources::ControlledNotificationSource, Timeline::Sources::CampaignSource ].flat_map { |s| entries(s) }
    expect(entries.size).to eq(4)
    citizen_view = entries.map { |e| e.citizen.to_s + e.document.to_s }.join(" ")
    expect(citizen_view).not_to include("CONTEUDO-SECRETO-ATESTADO", "PR-7654321", "CLONAZEPAM", "Refere sede", "Metformina")
    expect(entries.map { |e| e.to_h.to_s }.join(" ")).not_to include("CONTEUDO-SECRETO-ATESTADO", "Refere sede", "Metformina")
    expect(campaign).to be_present
  end
end

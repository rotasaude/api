require "rails_helper"

# Módulo 31 (ADR 0049; contrato §10): nada do CAPS vai ao LEDI. Atendimento
# numa unidade `caps` (que o P32 já impede de nascer pelo check-in) não
# enfileira a ficha da consulta nem a da escuta, e a geração — também chamada
# pelo varredor das 23h e pelo "gerar de novo" — devolve :skipped sem ficha
# nem "não gerada". As ações e os documentos do CAPS não são origem de ficha
# (Ledi::FichaSources), então não há outro caminho.
RSpec.describe "LEDI — unidade CAPS" do
  let(:city) { ledi_ready!(clinical_city!, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902") }
  let(:caps) { HealthUnit.create!(name: "CAPS II Boa Vista", kind: "caps", caps_modality: "caps_ii", service_classification: "001") }

  before do
    Current.city = city
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear # o adaptador de teste acumula entre exemplos
    ciap2_release!; cid10_release!; sigtap_release!
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end
  after { Current.reset }

  def enqueued(job) = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == job }

  it "consulta finalizada no CAPS: não enfileira a ficha, e a geração direta pula" do
    doctor = doctor!(caps)
    exportable_unit!(caps, doctor)
    consultation = finalized_consultation!(unit: caps, doctor: doctor, citizen: verified_citizen!(1))
    expect(enqueued(Ledi::ConsultationFichaJob)).to be_empty
    expect(Ledi::ConsultationFichaJob.enqueue_for(consultation)).to be_nil
    expect(Ledi::ConsultationFichaJob.enqueue_for(consultation, reason: "addendum")).to be_nil
    expect(enqueued(Ledi::ConsultationFichaJob)).to be_empty
    expect(Ledi::ConsultationFicha.generate(consultation, city: city)).to eq(:skipped)
    expect(LediOutboxEntry.where(source_id: consultation.id)).to be_empty
    expect(LediGenerationFailure.where(source_id: consultation.id)).to be_empty
  end

  it "escuta concluída no CAPS: não enfileira a ficha, e a geração direta pula" do
    nurse = screener!(caps)
    exportable_unit!(caps, nurse)
    attendance = walk_in_attendance!(caps, citizen: screening_citizen!(1))
    screening = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    result = Screenings::Complete.call(screening: screening, revision_params: revision_params, destination: "oriented",
                                       destination_params: { "orientation_note" => "repouso" }, by: nurse)
    expect(result).to be_ok
    expect(enqueued(Ledi::ScreeningFichaJob)).to be_empty
    expect(Ledi::ScreeningFichaJob.enqueue_for(screening.reload)).to be_nil
    expect(Ledi::ScreeningFicha.generate(screening, city: city)).to eq(:skipped)
    expect(LediOutboxEntry.where(source_id: screening.id)).to be_empty
    expect(LediGenerationFailure.where(source_id: screening.id)).to be_empty
  end

  it "as origens de ficha nunca incluem ação nem documento do CAPS" do
    expect(Ledi::FichaSources::REGISTRY.keys.grep(/Psychosocial|ClinicalDocument/)).to eq([])
  end
end

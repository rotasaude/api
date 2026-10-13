require "rails_helper"

# ADR 0031 (spec §6): a finalização enfileira a ficha; adendo com mudança
# estruturada enfileira a regeneração; só texto, nada.
RSpec.describe Ledi::ConsultationFichaJob do
  let(:city) { ledi_ready!(clinical_city!, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902") }
  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }

  before do
    Current.city = city
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear # o adaptador de teste acumula entre exemplos
    ciap2_release!; cid10_release!; sigtap_release!
    allow(Ledi::DeliverJob).to receive(:perform_later)
    exportable_unit!(unit, doctor)
  end
  after { Current.reset }

  def enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == described_class }

  it "finalizar enfileira; o job gera; adendo estruturado enfileira refresh; adendo só texto não" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    expect(enqueued.size).to eq(1)
    args = ActiveJob::Arguments.deserialize(enqueued.first[:args]).first
    expect(args).to eq(city_slug: city.slug, consultation_id: consultation.id, reason: "finalized")
    described_class.perform_now(**args)
    expect(LediOutboxEntry.where(source_id: consultation.id).count).to eq(1)
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "só texto acrescentado", text: "x")
    expect(enqueued.size).to eq(1)
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "conduta acrescentada", text: "x",
                                    changes: { "conducts" => [ 1, 9 ] })
    expect(ActiveJob::Arguments.deserialize(enqueued.last[:args]).first).to include(reason: "addendum")
  end

  it "o job leva só ids" do
    finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1, full_name: "Nome MARCADOR"))
    expect(enqueued.to_json).not_to include("MARCADOR", "Diabetes")
  end

  it "depois da 10ª tentativa com a ficha em envio, registra a falha 'seguia em envio' (api#52)" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    allow(Ledi::ConsultationFicha).to receive(:refresh!).and_raise(Ledi::ConsultationFicha::InFlight)
    job = described_class.new(city_slug: city.slug, consultation_id: consultation.id, reason: "addendum")
    # O retry_on conta as tentativas por exceção (exception_executions), não pelo executions.
    job.exception_executions = { [ Ledi::ConsultationFicha::InFlight ].to_s => 9 } # a próxima é a 10ª

    job.perform_now

    expect(LediGenerationFailure.unresolved.find_by(source_id: consultation.id)&.reason_codes).to eq([ "still_sending" ])
  end
end


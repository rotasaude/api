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
end

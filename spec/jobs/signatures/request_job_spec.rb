require "rails_helper"

# ADR 0032 (spec §5, finalização; adoção por profissional): o 19a não muda; o
# consumidor dos eventos abre o pedido só com o interruptor utilizável e o autor
# com certificado ativo, e enfileira o job. Finalizar nunca espera.
RSpec.describe Signatures::RequestJob do
  include ActiveJob::TestHelper

  before do
    Current.city = signature_city!
    ciap2_release!; cid10_release!; sigtap_release!
  end
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }

  def consume!(name)
    DomainEvent.where(name: name).order(:occurred_at).each do |event|
      described_class.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
    end
  end

  it "está ligado aos dois eventos do 19a" do
    %w[consultation.finalized consultation.addendum_added].each do |name|
      expect(DomainEvents.registry[name].map(&:job)).to include("Signatures::RequestJob")
    end
  end

  it "autor com certificado: pedido pending e job enfileirado; consumir de novo não duplica" do
    linked_certificate!(doctor)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    expect { consume!("consultation.finalized") }.to have_enqueued_job(Signatures::SignJob)
    request = SignatureRequest.sole
    expect(request).to have_attributes(document_type: "Consultation", document_id: consultation.id,
                                       consultation_id: consultation.id, author_user_id: doctor.id, status: "pending", attempts: 0)
    expect { consume!("consultation.finalized") }.not_to change(SignatureRequest, :count)
    expect(Signatures::OpenRequest.call(consultation)).to eq(:exists)
  end

  it "autor sem certificado: nada nasce (manual); interruptor desligado: nada nasce" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    consume!("consultation.finalized")
    expect(SignatureRequest.count).to eq(0)
    expect(Signatures::OpenRequest.call(consultation)).to eq(:manual)

    linked_certificate!(doctor)
    signature_city!(enabled: false)
    other = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    expect(Signatures::OpenRequest.call(other)).to eq(:unusable)
    expect { consume!("consultation.finalized") }.not_to have_enqueued_job(Signatures::SignJob)
    expect(SignatureRequest.count).to eq(0)
  end

  it "adendo: o pedido é da autora da consulta; sem certificado nada nasce; outro profissional não cria adendo nem pedido" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    expect(Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "primeiro adendo aqui", text: "UM")).to be_ok
    consume!("consultation.addendum_added")
    expect(SignatureRequest.count).to eq(0) # autora sem certificado: o adendo fica no papel

    linked_certificate!(doctor)
    added = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "segundo adendo aqui", text: "DOIS")
    expect(added).to be_ok
    second = added.payload[:addendum]
    other = signer_doctor!(unit, cpf: SignatureHelpers::OTHER_CPF)
    linked_certificate!(other)
    denied = Consultations::AddAddendum.call(consultation: consultation, by: other, reason: "terceiro adendo aqui", text: "TRES")
    expect(denied).to be_failure
    expect(denied.reason).to eq(:not_author)
    expect(ConsultationAddendum.count).to eq(2)

    consume!("consultation.addendum_added")
    expect(SignatureRequest.pluck(:document_type, :document_id, :author_user_id, :consultation_id))
      .to eq([ [ "ConsultationAddendum", second.id, doctor.id, consultation.id ] ])
  end

  it "finalizar nunca espera o PSC nem o signer (o consumidor só enfileira)" do
    stub_psc!
    fake_psc.failures.push(503, 503, 503)
    stub_signer!.unavailable = true
    linked_certificate!(doctor)
    expect { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }.not_to raise_error
    expect { consume!("consultation.finalized") }.not_to raise_error
    expect(fake_psc.log).to be_empty
    expect(SignatureRequest.sole.status).to eq("pending")
  end

  it "tentativas e motivos: com PSC/signer fora, finalizar responde como no 19a e o pedido termina pending com o motivo" do
    stub_psc!
    signer = stub_signer!
    certificate = linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    signature_session!(doctor, certificate: certificate, token: fake_psc.token_for!(cpf: SignatureHelpers::DOCTOR_CPF))
    signer.unavailable = true
    consultation = nil
    expect { consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }.not_to raise_error
    expect(consultation.reload).to be_finalized
    consume!("consultation.finalized")
    request = SignatureRequest.sole
    slug = Current.city.slug
    3.times { Signatures::SignJob.perform_now(city_slug: slug, request_id: request.id) }
    expect(request.reload).to have_attributes(status: "pending", attempts: 3, reason_code: "signer_unavailable")
    expect(consultation.reload).to be_finalized
  end
end

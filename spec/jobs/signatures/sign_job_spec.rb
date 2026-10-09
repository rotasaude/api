# spec/jobs/signatures/sign_job_spec.rb
require "rails_helper"

# O job reenfileira a si mesmo na falha passageira, com espera crescente.
RSpec.describe Signatures::SignJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  before do
    Current.city = signature_city!
    stub_psc!
    @signer = stub_signer!
  end
  after { Current.reset }

  it "falha passageira: reenfileira com 30 s e depois 2 min; na 3ª tentativa fica pending sem reenfileirar" do
    ciap2_release!; cid10_release!; sigtap_release!
    unit = create_unit
    doctor = signer_doctor!(unit)
    certificate = linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    signature_session!(doctor, certificate: certificate, token: fake_psc.token_for!(cpf: SignatureHelpers::DOCTOR_CPF))
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    request = signature_request!(consultation, author: doctor)
    @signer.unavailable = true # signer fora do ar: signer_unavailable (passageiro)
    slug = Current.city.slug
    freeze_time do
      expect { described_class.perform_now(city_slug: slug, request_id: request.id) }
        .to have_enqueued_job(described_class).with(city_slug: slug, request_id: request.id).at(30.seconds.from_now)
      expect { described_class.perform_now(city_slug: slug, request_id: request.id) }
        .to have_enqueued_job(described_class).at(2.minutes.from_now)
      expect { described_class.perform_now(city_slug: slug, request_id: request.id) }.not_to have_enqueued_job(described_class)
    end
    expect(request.reload).to have_attributes(attempts: 3, reason_code: "signer_unavailable", status: "pending")
  end

  it "falha determinística (documento inexistente): pending sem reenfileirar" do
    doctor = signer_doctor!(create_unit)
    certificate = linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    signature_session!(doctor, certificate: certificate, token: fake_psc.token_for!(cpf: SignatureHelpers::DOCTOR_CPF))
    request = signature_request!(author: doctor)
    expect { described_class.perform_now(city_slug: Current.city.slug, request_id: request.id) }.not_to have_enqueued_job(described_class)
    expect(request.reload).to have_attributes(attempts: 0, reason_code: "verification_failed", status: "pending")
  end

  it "sucesso: assina e não reenfileira" do
    ciap2_release!; cid10_release!; sigtap_release!
    unit = create_unit
    doctor = signer_doctor!(unit)
    certificate = linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    signature_session!(doctor, certificate: certificate, token: fake_psc.token_for!(cpf: SignatureHelpers::DOCTOR_CPF))
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    request = signature_request!(consultation, author: doctor)
    expect { described_class.perform_now(city_slug: Current.city.slug, request_id: request.id) }.not_to have_enqueued_job(described_class)
    expect(request.reload).to have_attributes(status: "signed", attempts: 0)
    expect(request.signature).to be_present
  end

  it "não atribui Current.city: rodado sem cidade, sai sem cidade (CityScopedJob)" do
    doctor = signer_doctor!(create_unit)
    request = signature_request!(author: doctor)
    slug = Current.city.slug
    Current.reset
    described_class.perform_now(city_slug: slug, request_id: request.id)
    expect(Current.city).to be_nil
    expect(CityConnection.with(City.find_by!(slug: slug)) { request.reload.reason_code }).to eq("no_session")
  end
end

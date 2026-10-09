require "rails_helper"

# ADR 0032, decisão do usuário 2026-10-09 (Task 20): com o interruptor
# utilizável e o autor com certificado ativo, o pedido de assinatura nasce NA
# finalização (e no adendo), na mesma transação, já pending; o SignJob vai para
# a fila `signatures` só depois do commit. O consumidor do evento não duplica.
# Sem certificado ou com o interruptor desligado, tudo como no 19a.
RSpec.describe "Pedido de assinatura nascido na finalização", type: :request do
  include ActiveJob::TestHelper

  before do
    signature_city!
    ciap2_release!; cid10_release!; sigtap_release!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  def body = JSON.parse(response.body)
  def sign_jobs = enqueued_jobs.select { |job| job[:job] == Signatures::SignJob }

  def draft!(citizen_index = 1)
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(citizen_index))
    saved = Consultations::SaveDraft.call(consultation: consultation, params: draft_body, by: doctor)
    raise "rascunho recusado: #{saved.reason}" if saved.failure?

    consultation
  end

  def finalize!(consultation)
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/finalize", outcome: { outcome: "discharged" }
  end

  def add_addendum!(consultation, reason: "acréscimo de dados")
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/addenda", reason: reason, text: "texto do adendo"
  end

  def consume!(name)
    DomainEvent.where(name: name).order(:occurred_at).each do |event|
      Signatures::RequestJob.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
    end
  end

  def consuming(name)
    Current.city = signature_city!
    yield
  ensure
    Current.reset
  end

  context "autor com certificado ativo e interruptor utilizável" do
    before { linked_certificate!(doctor) }

    it "finalizar: resposta já pending com request_id; pedido pending; SignJob na fila signatures" do
      consultation = draft!
      finalize!(consultation)
      expect(response).to have_http_status(:ok)
      request = SignatureRequest.sole
      expect(request).to have_attributes(document_type: "Consultation", document_id: consultation.id,
                                         author_user_id: doctor.id, status: "pending", attempts: 0)
      expect(body["status"]).to eq("finalized")
      expect(body["signature"]).to eq("mode" => "pending", "request_id" => request.id)
      expect(sign_jobs.size).to eq(1)
      expect(sign_jobs.first).to include(queue: "signatures")
      expect(sign_jobs.first[:args].first).to include("request_id" => request.id)
    end

    it "o consumidor do evento depois não cria segundo pedido nem segundo SignJob" do
      finalize!(draft!)
      expect(SignatureRequest.count).to eq(1)
      clear_enqueued_jobs
      consuming("consultation.finalized") { consume!("consultation.finalized") }
      expect(SignatureRequest.count).to eq(1)
      expect(sign_jobs).to be_empty
    end

    it "finaliza com signer e PSC fora do ar: 200, finalizada, pedido pending (nenhuma chamada externa)" do
      stub_psc!
      fake_psc.failures.push(*Array.new(5, 503))
      stub_signer!.unavailable = true
      consultation = draft!
      finalize!(consultation)
      expect(response).to have_http_status(:ok)
      expect(consultation.reload).to be_finalized
      expect(SignatureRequest.sole.status).to eq("pending")
      expect(fake_psc.log).to be_empty
    end

    it "adendo: 201 já pending; pedido da autora; SignJob na fila signatures; consumidor não duplica" do
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
      clear_enqueued_jobs
      add_addendum!(consultation)
      expect(response).to have_http_status(:created)
      addendum = ConsultationAddendum.sole
      request = SignatureRequest.find_by!(document_type: "ConsultationAddendum", document_id: addendum.id)
      expect(request).to have_attributes(author_user_id: doctor.id, consultation_id: consultation.id, status: "pending")
      expect(body["signature"]).to eq("mode" => "pending", "request_id" => request.id)
      expect(sign_jobs.map { |job| job[:queue] }).to eq([ "signatures" ])

      clear_enqueued_jobs
      consuming("consultation.addendum_added") { consume!("consultation.addendum_added") }
      expect(SignatureRequest.where(document_type: "ConsultationAddendum").count).to eq(1)
      expect(sign_jobs).to be_empty
    end

    it "adendo com signer e PSC fora do ar: 201, pedido pending" do
      stub_psc!
      fake_psc.failures.push(*Array.new(5, 503))
      stub_signer!.unavailable = true
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
      add_addendum!(consultation)
      expect(response).to have_http_status(:created)
      expect(SignatureRequest.find_by!(document_type: "ConsultationAddendum").status).to eq("pending")
      expect(fake_psc.log).to be_empty
    end
  end

  context "a transação da finalização volta atrás" do
    before do
      linked_certificate!(doctor)
      Current.city = signature_city!
    end
    after { Current.reset }

    it "falha depois de abrir o pedido (no mesmo savepoint): nem pedido nem SignJob" do
      consultation = draft!
      allow(DomainEvents).to receive(:publish).and_raise(RuntimeError, "boom")
      expect { Consultations::Finalize.call(consultation: consultation, outcome_params: { "outcome" => "discharged" }, by: doctor) }
        .to raise_error(RuntimeError, "boom")
      expect(SignatureRequest.count).to eq(0)
      expect(sign_jobs).to be_empty
      expect(consultation.reload).to be_draft
    end

    it "transação externa desfeita: nem pedido nem SignJob (enfileira só no commit)" do
      consultation = draft!
      ApplicationRecord.transaction do
        result = Consultations::Finalize.call(consultation: consultation, outcome_params: { "outcome" => "discharged" }, by: doctor)
        expect(result).to be_ok
        expect(SignatureRequest.count).to eq(1)
        expect(sign_jobs).to be_empty # ainda não commitou
        raise ActiveRecord::Rollback
      end
      expect(SignatureRequest.count).to eq(0)
      expect(sign_jobs).to be_empty
    end

    it "adendo desfeito na transação externa: nem pedido nem SignJob" do
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
      clear_enqueued_jobs
      ApplicationRecord.transaction do
        added = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "acréscimo de dados", text: "UM")
        expect(added).to be_ok
        raise ActiveRecord::Rollback
      end
      expect(SignatureRequest.where(document_type: "ConsultationAddendum").count).to eq(0)
      expect(sign_jobs).to be_empty
    end
  end

  context "como no 19a" do
    it "sem certificado: manual, nenhum pedido, nenhum SignJob (finalização e adendo)" do
      consultation = draft!
      finalize!(consultation)
      expect(response).to have_http_status(:ok)
      expect(body["signature"]).to eq("mode" => "manual")
      add_addendum!(consultation)
      expect(response).to have_http_status(:created)
      expect(body["signature"]).to eq("mode" => "manual")
      expect(SignatureRequest.count).to eq(0)
      expect(sign_jobs).to be_empty
    end

    it "interruptor desligado: manual, nenhum pedido, nenhum SignJob" do
      linked_certificate!(doctor)
      signature_city!(enabled: false)
      consultation = draft!
      finalize!(consultation)
      expect(response).to have_http_status(:ok)
      expect(body["signature"]).to eq("mode" => "manual")
      add_addendum!(consultation)
      expect(response).to have_http_status(:created)
      expect(body["signature"]).to eq("mode" => "manual")
      expect(SignatureRequest.count).to eq(0)
      expect(sign_jobs).to be_empty
    end

    it "certificado não ativo (revogado): manual" do
      linked_certificate!(doctor, status: "revoked")
      finalize!(draft!)
      expect(body["signature"]).to eq("mode" => "manual")
      expect(SignatureRequest.count).to eq(0)
      expect(sign_jobs).to be_empty
    end
  end
end

require "rails_helper"

# Módulo 30, Task 17 (ADR 0048; Desvio 17; contrato §12; §14 T23; T39): o
# processo de TFD (rascunho inclusive) é registro retido — com ele, os
# trechos, os passageiros de origem tfd, as ajudas, os pagamentos e o
# comprovante da prestação de contas com o nome do arquivo (Portaria 55, arts.
# 15–16). Sem TFD, a confirmação da exclusão:
#   - suspende as séries do paciente a partir de hoje (e as tira das viagens futuras);
#   - retira o paciente de toda viagem aberta (planned/confirmed e in_progress);
#   - anonimiza todas as linhas de passageiro (cifradas → NULL, anonymized_at),
#     mantendo a presença e as contagens do painel, e as cifradas da série;
#   - apaga os avisos de viagem dos pares.
RSpec.describe "Exclusão LGPD com transporte sanitário e TFD (ADR 0048)" do
  include ActiveJob::TestHelper

  before do
    # O caminho real sempre tem atendimento no par: aqui ele é desligado para isolar a regra nova.
    allow(Citizens::RequestErasure).to receive_messages(attended?: false, documented?: false)
  end

  let!(:city) { transport_city!(tfd: true) }
  let(:patient) { transport_patient! }
  let(:citizen) { Patients::Pairs.of(patient).sole }
  let(:dest) { destination! }

  def encrypted = %w[provider_name address companion_name companion_document companion_reason exception_note remove_reason]
  def request_for(citizen) = Citizens::RequestErasure.call(cpf: citizen.cpf, document_checked: true, by: verifier!)
  def staffed_trip!(**over) = trip!(vehicle: vehicle!(seats: 4), driver: driver_user!.transport_driver, destination: dest, **over)

  def companion
    { companion_name: "Maria Acompanhante", companion_document: "12345678909", companion_reason: "Mãe idosa acompanha o filho",
      companion_attendance: "pending" }
  end

  def series!(**over)
    TransportSeries.create!({ patient: patient, transport_destination: dest, weekdays: (1..7).to_a, appointment_time: "07:00",
                              departure_time: "05:30", return_time: "12:00", boarding_label: "Praça Central",
                              starts_on: Date.current - 10, created_by_user: dispatcher!, provider_name: "Clínica do Rim",
                              address: "Rua das Clínicas, 10", companion_name: "Maria Acompanhante",
                              companion_document: "12345678909", companion_reason: "Mãe idosa acompanha o filho" }.merge(over))
  end

  def proof
    { "content_type" => "application/pdf", "data" => Base64.strict_encode64(ExamHelpers::PDF_BYTES),
      "filename" => "comprovante-maria.pdf" }
  end

  describe "retenção pelo TFD" do
    it "processo de TFD em rascunho: o pedido nasce retido, e só o TFD retém" do
      tfd_case!(status: "draft", patient: patient)
      expect(Citizens::RequestErasure.tfd_cased?([ patient.id ])).to be(true)
      expect(request_for(citizen).payload[:request].status).to eq("retained")

      allow(Citizens::RequestErasure).to receive(:tfd_cased?).and_return(false)
      expect(Citizens::RequestErasure.examined_patients?([ patient.id ])).to be(false)
    end

    it "tfd_cased? é falso sem processo" do
      expect(Citizens::RequestErasure.tfd_cased?([ patient.id ])).to be(false)
    end

    it "TFD chegado depois do pedido: a confirmação retém e nada se toca, comprovante e nome do arquivo inclusive" do
      request = request_for(citizen).payload[:request]
      expect(request.status).to eq("pending")

      tfd = tfd_case!(status: "travelling", patient: patient)
      closed = Tfd::CloseAccountability.call(tfd_case: tfd, attrs: proof, by: committee!)
      expect(closed.failure?).to be(false)
      account = closed.payload.fetch(:accountability)
      trip = staffed_trip!(status: "done", date: Date.current)
      rider = passenger!(trip, patient: patient, origin: "tfd", tfd_case: tfd, exception_reason: nil, provider_name: "Hospital de Londrina",
                               attendance: "boarded")

      result = Citizens::Erase.call(request: request, by: care_admin!)
      expect(result.payload[:request].status).to eq("retained")
      expect(citizen.reload.erased_at).to be_nil
      row = TfdAccountability.find(account.id)
      expect(row.filename).to eq("comprovante-maria.pdf")
      expect(ExamFile.find(row.exam_file_id).bytes).to eq(ExamHelpers::PDF_BYTES)
      expect(tfd.reload.status).to eq("completed")
      expect(rider.reload).to have_attributes(anonymized_at: nil, provider_name: "Hospital de Londrina")
    end
  end

  describe "sem TFD: confirmação" do
    let(:admin) { care_admin! }

    it "quem só viajou: confirmado; o passageiro da viagem feita é anonimizado, presença e painel ficam" do
      done = staffed_trip!(status: "done", date: Date.current)
      rider = passenger!(done, patient: patient, provider_name: "Hospital do Rim", address: "Rua das Clínicas, 10",
                               **companion, attendance: "boarded", companion_attendance: "boarded")
      month = Date.current.strftime("%Y-%m")
      before_panel = Transport::Dashboard.call(month: month, tfd_enabled: false)
      expect(before_panel[:occupancy_pct]).to eq(50)

      request = request_for(citizen).payload[:request]
      expect(request.status).to eq("pending")
      result = Citizens::Erase.call(request: request, by: admin)
      expect(result.payload[:request].status).to eq("confirmed")

      rider.reload
      expect(rider.anonymized_at).to be_present
      encrypted.each { |column| expect(rider.read_attribute_before_type_cast(column)).to be_nil, column }
      expect(rider).to have_attributes(attendance: "boarded", companion_attendance: "boarded", removed_at: nil, patient_id: patient.id)
      expect(Transport::Dashboard.call(month: month, tfd_enabled: false)).to eq(before_panel)
    end

    it "avisos de viagem dos pares apagados" do
      trip = staffed_trip!(status: "confirmed", date: Date.current + 3)
      rider = passenger!(trip, patient: patient)
      TransportTripNotice.create!(transport_trip_passenger: rider, citizen: citizen, kind: "added", event_key: "once",
                                  departure_at: trip.departure_at, boarding_label: "Praça Central", created_at: Time.current)
      other = passenger!(trip)
      kept = TransportTripNotice.create!(transport_trip_passenger: other, citizen: Patients::Pairs.of(other.patient).sole, kind: "added",
                                         event_key: "once", departure_at: trip.departure_at, boarding_label: "Praça Central",
                                         created_at: Time.current)

      Citizens::Erase.call(request: request_for(citizen).payload[:request], by: admin)
      expect(TransportTripNotice.where(citizen_id: citizen.id)).not_to exist
      expect(TransportTripNotice.where(id: kept.id)).to exist
    end

    it "série suspensa a partir de hoje e fora das viagens futuras; viagens abertas sem o paciente; tudo anonimizado depois" do
      series = series!
      future = staffed_trip!(status: "confirmed", date: Date.current + 2)
      from_series = passenger!(future, patient: patient, origin: "series", transport_series: series, exception_reason: nil, **companion)
      planned = trip!(status: "planned", date: Date.current + 9, destination: dest)
      exception = passenger!(planned, patient: patient, exception_note: "Retorno de consulta na clínica")
      running = staffed_trip!(status: "in_progress", date: Date.current)
      on_board = passenger!(running, patient: patient, attendance: "boarded")
      neighbour = passenger!(future)

      result = Citizens::Erase.call(request: request_for(citizen).payload[:request], by: admin)
      expect(result.payload[:request].status).to eq("confirmed")

      series.reload
      expect(series).to have_attributes(suspended_from: Date.current, suspend_reason: Transport::Anonymize::REASON)
      expect(series.runs_on?(Date.current + 2)).to be(false)
      %w[provider_name address companion_name companion_document companion_reason].each do |column|
        expect(series.read_attribute_before_type_cast(column)).to be_nil, column
      end

      [ from_series, exception, on_board ].each do |row|
        row.reload
        # Retirado ANTES de anonimizar (o trigger congela a linha anonimizada):
        # removed_at gravado e o motivo da retirada já anulado.
        expect(row.removed_at).to be_present
        expect(row.removed_by_user_id).to eq(admin.id)
        expect(row.anonymized_at).to be_present
        encrypted.each { |column| expect(row.read_attribute_before_type_cast(column)).to be_nil, column }
      end
      expect(on_board.attendance).to eq("boarded")
      expect(neighbour.reload).to have_attributes(removed_at: nil, anonymized_at: nil)

      payloads = DomainEvent.where(name: "transport.passenger_removed").map(&:payload)
      expect(payloads).to include({ "trip_id" => future.id, "passenger_id" => from_series.id },
                                  { "trip_id" => planned.id, "passenger_id" => exception.id },
                                  { "trip_id" => running.id, "passenger_id" => on_board.id })
      payloads.each { |payload| expect(payload.keys).to contain_exactly("trip_id", "passenger_id") }
    end

    it "série já suspensa antes guarda a data e troca o motivo livre pelo fixo; série encerrada não é suspensa" do
      old = series!(suspended_from: Date.current - 3, suspend_reason: "Paciente internado no Hospital São Vicente")
      ended = series!(starts_on: Date.current - 30, ends_on: Date.current - 1)

      Citizens::Erase.call(request: request_for(citizen).payload[:request], by: admin)
      expect(old.reload).to have_attributes(suspended_from: Date.current - 3, suspend_reason: Transport::Anonymize::REASON)
      expect(ended.reload).to have_attributes(suspended_from: nil, suspend_reason: nil, companion_name: nil, provider_name: nil)
    end

    it "o trigger aceita a anonimização uma vez e recusa uma segunda UPDATE das cifradas; a segunda chamada não toca a linha" do
      done = staffed_trip!(status: "done", date: Date.current)
      rider = passenger!(done, patient: patient, provider_name: "Hospital do Rim", attendance: "boarded")
      expect(Transport::Anonymize.patients!([ patient.id ], by: admin)).to eq(1)
      stamp = rider.reload.anonymized_at

      expect(Transport::Anonymize.patients!([ patient.id ], by: admin)).to eq(0)
      expect(rider.reload.anonymized_at).to eq(stamp)
      expect { TransportTripPassenger.where(id: rider.id).update_all(provider_name: nil, anonymized_at: Time.current) }
        .to raise_error(ActiveRecord::StatementInvalid, /an anonymized passenger never changes/)
    end

    it "nada do paciente no log nem nos eventos" do
      series!
      trip = staffed_trip!(status: "confirmed", date: Date.current + 2)
      passenger!(trip, patient: patient, provider_name: "Hospital do Rim", **companion)
      log = capture_log { Citizens::Erase.call(request: request_for(citizen).payload[:request], by: admin) }
      payloads = DomainEvent.all.map { |event| event.payload.to_json }.join
      [ "Hospital do Rim", "Maria Acompanhante", "12345678909", "Clínica do Rim", patient.full_name ].compact.each do |text|
        expect(log).not_to include(text)
        expect(payloads).not_to include(text)
      end
    end
  end
end

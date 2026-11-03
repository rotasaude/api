require "rails_helper"

# Módulo 30, Task 12 (ADR 0048; contrato §6; §14 T8, T13, T18, T24): pagamento
# registrado da ajuda de custo (imutável) e prestação de contas com o
# comprovante (JSON base64, Exams::Files, URL curta de 5 min). Comissão com
# step-up; toda escrita devolve o <tfd-case> inteiro.
RSpec.describe "TFD — pagamento e prestação de contas", type: :request do
  let!(:city) { transport_city!(tfd: true, billing: true) }
  let(:committee) { committee! }
  let(:patient) { transport_patient! }
  let(:png) { "\x89PNG\r\n\x1A\n".b + "comprovante-bytes".b }
  let(:proof) { { content_type: "image/png", data: Base64.strict_encode64(png), filename: "comprovante-joao.png" } }
  let(:payment) { { paid_on: Date.current.iso8601, amount_cents: 24_750, method: "pix", receipt_number: "REC-SECRETO-77" } }

  def pay(tfd, body = payment) = json_post("/tfd/cases/#{tfd.id}/payments", body)
  def close(tfd, body = proof) = json_post("/tfd/cases/#{tfd.id}/accountability", body)
  def errors = json_body["problems"].map { |p| p["error"] }
  def paths = json_body["problems"].map { |p| p["path"] }
  def payloads(name) = DomainEvent.where(name: name).map(&:payload)

  # Processo em `travelling` com a ida de passagem feita; `with_return: true` deixa a volta aberta.
  def travelling_case!(with_return: false)
    tfd = tfd_case!(status: "authorized", patient: patient)
    ticket = { amount_cents: 15_000, carrier: "Viação Garcia" }
    json_post("/tfd/cases/#{tfd.id}/legs", { direction: "outbound", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket })
    json_post("/tfd/legs/#{json_body['legs'].sole['id']}/done")
    if with_return
      json_post("/tfd/cases/#{tfd.id}/legs", { direction: "return", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket })
    end
    expect(tfd.reload.status).to eq("travelling")
    tfd
  end

  before { stepped_up!(committee) }

  describe "pagamento" do
    it "grava, aparece em payments com by_name, devolve o <tfd-case> e publica só ids" do
      tfd = tfd_case!(status: "scheduled", patient: patient)
      pay(tfd)
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to include("id", "patient", "report", "legs", "payments", "events")
      row = json_body["payments"].sole
      expect(row).to include("paid_on" => Date.current.iso8601, "amount_cents" => 24_750, "method" => "pix",
                             "receipt_number" => "REC-SECRETO-77")
      expect(row["by_name"]).to be_present
      expect(TfdPayment.sole.payment_method).to eq("pix")
      saved = TfdPayment.sole
      expect(payloads("tfd.payment_recorded")).to contain_exactly(
        { "tfd_case_id" => tfd.id, "tfd_payment_id" => saved.id, "user_id" => committee.id }
      )
      expect(payloads("tfd.payment_recorded").to_s).not_to include("REC-SECRETO", "24750")
    end

    it "method fora da lista, valor, recibo e data inválidos: todas as recusas juntas" do
      tfd = tfd_case!(status: "scheduled", patient: patient)
      pay(tfd, paid_on: (Date.current + 1).iso8601, amount_cents: 0, method: "boleto", receipt_number: "")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("invalid_request")
      expect(json_body["problems"]).to include({ "path" => "method", "error" => "invalid_request" })
      expect(paths).to contain_exactly("paid_on", "amount_cents", "method", "receipt_number")

      pay(tfd, payment.merge(paid_on: (Date.current - 366).iso8601, amount_cents: Tfd::Catalog::MAX_AMOUNT_CENTS + 1,
                             receipt_number: "x" * 41, extra: 1))
      expect(paths).to contain_exactly("paid_on", "amount_cents", "receipt_number", "extra")

      pay(tfd, payment.merge(paid_on: (Date.current - 365).iso8601, amount_cents: Tfd::Catalog::MAX_AMOUNT_CENTS, receipt_number: "x" * 40))
      expect(response).to have_http_status(:ok)
      expect(TfdPayment.count).to eq(1)
    end

    it "só em scheduled/travelling; antes (authorized) e depois (completed) → invalid_transition" do
      pay(tfd_case!(status: "authorized", patient: patient))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("invalid_transition")
      pay(tfd_case!(status: "completed", patient: transport_patient!))
      expect(json_body["error"]).to eq("invalid_transition")
      expect(TfdPayment.count).to eq(0)
    end

    it "o número do recibo não vai ao log" do
      tfd = tfd_case!(status: "scheduled", patient: patient)
      log = capture_log { pay(tfd) }
      expect(response).to have_http_status(:ok)
      expect(log).not_to include("REC-SECRETO-77")
    end

    it "sem step-up → 401 mfa_required; outro papel → 403; rascunho → 404; pagamento é só acréscimo" do
      tfd = tfd_case!(status: "scheduled", patient: patient)
      sign_in_as(committee)
      pay(tfd)
      expect(response).to have_http_status(:unauthorized)
      expect(json_body).to eq("error" => "mfa_required")

      doctor = tfd.requester_user
      stepped_up!(doctor)
      pay(tfd)
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")

      stepped_up!(committee)
      pay(tfd_case!(status: "draft", patient: transport_patient!))
      expect(response).to have_http_status(:not_found)

      pay(tfd)
      expect { TfdPayment.sole.update_column(:amount_cents, 1) }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end

  describe "prestação de contas" do
    it "PNG falso (bytes de texto) → invalid_file e nada gravado" do
      tfd = travelling_case!
      close(tfd, proof.merge(data: Base64.strict_encode64("isto não é um PNG")))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("invalid_file")
      expect(tfd.reload.status).to eq("travelling")
      expect(TfdAccountability.count).to eq(0)
      expect(ExamFile.where(purpose: "tfd_accountability").count).to eq(0)
    end

    it "base64 inválido, tipo desconhecido e arquivo vazio → invalid_file; filename inválido → invalid_request" do
      tfd = travelling_case!
      close(tfd, proof.merge(data: "###"))
      expect(json_body["error"]).to eq("invalid_file")
      close(tfd, proof.merge(content_type: "text/plain"))
      expect(json_body["error"]).to eq("invalid_file")
      close(tfd, proof.merge(data: ""))
      expect(json_body["error"]).to eq("invalid_file")
      close(tfd, proof.merge(filename: "a" * 121))
      expect(json_body["error"]).to eq("invalid_request")
      expect(paths).to eq([ "filename" ])
      close(tfd, proof.merge(extra: 1))
      expect(paths).to eq([ "extra" ])
    end

    it "mais de 10 MB decodificados → invalid_file" do
      tfd = travelling_case!
      big = "\x89PNG\r\n\x1A\n".b + ("0".b * Exams::Files::MAX_BYTES)
      close(tfd, proof.merge(data: Base64.strict_encode64(big)))
      expect(json_body["error"]).to eq("invalid_file")
      expect(TfdAccountability.count).to eq(0)
    end

    it "com trecho pendente → legs_pending" do
      tfd = travelling_case!(with_return: true)
      close(tfd)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("legs_pending")
      expect(tfd.reload.status).to eq("travelling")
      expect(TfdAccountability.count).to eq(0)
    end

    it "fora de travelling (scheduled, completed) → invalid_transition" do
      close(tfd_case!(status: "scheduled", patient: patient))
      expect(json_body["error"]).to eq("invalid_transition")
      close(tfd_case!(status: "completed", patient: transport_patient!))
      expect(json_body["error"]).to eq("invalid_transition")
    end

    it "com tudo feito → completed, accountability.document.filename e evento só com ids; o nome do arquivo e os bytes não vão ao log" do
      tfd = travelling_case!
      log = capture_log { close(tfd) }
      expect(response).to have_http_status(:ok)
      expect(json_body["status"]).to eq("completed")
      expect(json_body["accountability"]).to include("closed_at")
      expect(json_body["accountability"]["document"]).to include("filename" => "comprovante-joao.png")
      expect(json_body["events"].last["kind"]).to eq("completed")

      row = TfdAccountability.sole
      file = ExamFile.find(row.exam_file_id)
      expect(file.purpose).to eq("tfd_accountability")
      expect(file.consumed?).to be(true)
      expect(file.bytes).to eq(png)
      expect(row.filename_before_type_cast).not_to include("comprovante-joao")
      expect(payloads("tfd.accountability_closed")).to contain_exactly({ "tfd_case_id" => tfd.id, "user_id" => committee.id })
      expect(log).not_to include("comprovante-joao", Base64.strict_encode64(png))

      close(tfd)
      expect(json_body["error"]).to eq("invalid_transition")
    end

    it "sem filename o api gera um nome com a extensão do tipo" do
      tfd = travelling_case!
      close(tfd, proof.except(:filename))
      expect(response).to have_http_status(:ok)
      expect(json_body["accountability"]["document"]["filename"]).to match(/\A[\w-]+\.png\z/)
    end

    it "sem step-up → 401; outro papel → 403" do
      tfd = travelling_case!
      sign_in_as(committee)
      close(tfd)
      expect(response).to have_http_status(:unauthorized)
      stepped_up!(tfd.requester_user)
      close(tfd)
      expect(response).to have_http_status(:forbidden)
      expect(tfd.reload.status).to eq("travelling")
    end
  end

  describe "comprovante por URL curta" do
    let(:tfd) { travelling_case! }
    let(:other) { committee! }

    before { close(tfd) }

    def link
      json_post("/tfd/cases/#{tfd.id}/accountability/url")
      json_body["url"]
    end

    it "POST .../accountability/url devolve { url } e o GET baixa os bytes" do
      url = link
      expect(response).to have_http_status(:ok)
      expect(url).to match(%r{\A/tfd/files/.+})
      get url
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.body.b).to eq(png)
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "link de outro usuário → 404; token falso → 404" do
      url = link
      stepped_up!(other)
      get url
      expect(response).to have_http_status(:not_found)
      get "/tfd/files/abc"
      expect(response).to have_http_status(:not_found)
    end

    it "depois de 5 minutos → 410 link_expired" do
      file = ExamFile.find(TfdAccountability.sole.exam_file_id)
      url = Tfd::Files.url_for(file, user: committee, now: 6.minutes.ago)
      get url
      expect(response).to have_http_status(:gone)
      expect(json_body["error"]).to eq("link_expired")
    end

    it "link do 21a (exam_file) não abre pela rota do TFD; sem comprovante → 404; outro papel → 403" do
      exam_url = Exams::Files.url_for(ExamFile.find(TfdAccountability.sole.exam_file_id), user: committee)
      get exam_url.sub("/exams/", "/tfd/")
      expect(response).to have_http_status(:not_found)

      json_post("/tfd/cases/#{tfd_case!(status: 'scheduled', patient: transport_patient!).id}/accountability/url")
      expect(response).to have_http_status(:not_found)

      token = link.split("/").last
      stepped_up!(tfd.requester_user)
      json_post("/tfd/cases/#{tfd.id}/accountability/url")
      expect(response).to have_http_status(:forbidden)
      get "/tfd/files/#{token}"
      expect(response).to have_http_status(:forbidden)
    end
  end
end

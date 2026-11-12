require "rails_helper"

# Módulo 33 (ADR 0051; contrato §3/§5; Q2, Q14, Q43): anexos da manifestação.
# O upload devolve só o id e nasce órfão (dono = a sessão do cidadão ou o
# técnico); a ligação (Attachments.link!) consome o arquivo na mesma transação;
# o download é só da equipe, pela URL curta assinada. O nome do arquivo é
# cifrado e nunca aparece.
RSpec.describe "Ouvidoria — anexos", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { ombudsman_city! }
  let(:technician) { ombudsman_staff! }
  let(:ouvidor) { ombudsman! }
  let(:marker) { "sigiloso-#{SecureRandom.hex(4)}" }

  def upload(path, data: png_base64, content_type: "image/png", filename: "#{marker}.png")
    json_post path, filename: filename, content_type: content_type, data: data
  end

  def capture_log
    log = StringIO.new
    capture = ActiveSupport::Logger.new(log).tap { |l| l.level = Logger::DEBUG }
    Rails.logger.broadcast_to(capture)
    yield
    log.string
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  def memory_cache! = allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

  describe "POST /citizen/ombudsman/attachments" do
    it "PNG válido sobe (201 só com o id) e nasce órfão, do dono da sessão, com o nome cifrado" do
      session = sign_in_citizen
      log = capture_log { upload "/citizen/ombudsman/attachments" }
      expect(response).to have_http_status(:created)
      expect(json_body.keys).to eq([ "id" ])
      expect(response.body).not_to include(marker)

      attachment = OmbudsmanAttachment.find(json_body["id"])
      expect(attachment).to have_attributes(ombudsman_manifestation_id: nil, event_id: nil, uploaded_by: "citizen",
                                            citizen_session_id: session.id, uploaded_by_user_id: nil, filename: "#{marker}.png")
      expect(OmbudsmanAttachment.connection.select_value("SELECT filename FROM ombudsman_attachments WHERE id = '#{attachment.id}'"))
        .not_to include(marker)
      expect(attachment.exam_file).to have_attributes(purpose: "ombudsman_attachment", consumed_at: nil, content_type: "image/png",
                                                      uploaded_by_user_id: nil)
      expect(log).not_to include(marker)
    end

    it "texto com cabeçalho falso de PDF → 422 invalid_file; 11 MB → 422; tipo desconhecido → 422" do
      sign_in_citizen
      upload "/citizen/ombudsman/attachments", data: Base64.strict_encode64("texto simples"), content_type: "application/pdf"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]).to eq("invalid_file")

      big = Base64.strict_encode64("\x89PNG\r\n\x1A\n".b + ("a".b * (11 * 1024 * 1024)))
      upload "/citizen/ombudsman/attachments", data: big
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]).to eq("invalid_file")

      upload "/citizen/ombudsman/attachments", content_type: "image/gif"
      expect(json_body["error"]).to eq("invalid_file")
      upload "/citizen/ombudsman/attachments", data: "não é base64!"
      expect(json_body["error"]).to eq("invalid_file")
      expect(OmbudsmanAttachment.count).to eq(0)
      expect(ExamFile.count).to eq(0)
    end

    it "valida o nome (1..120, sem barra nem caractere de controle) e os tipos dos campos" do
      sign_in_citizen
      [ "", "   ", "a" * 121, "../x.png", "a/b.png", "a\\b.png", "a\nb.png", "a\u0000b.png", nil, 12, [ "x.png" ] ].each do |bad|
        upload "/citizen/ombudsman/attachments", filename: bad
        expect(response).to have_http_status(:unprocessable_content), "esperava 422 para #{bad.inspect}"
        expect(json_body).to include("error" => "invalid_request", "path" => "filename")
      end
      json_post "/citizen/ombudsman/attachments", filename: "anexo-1.png", content_type: "image/png"
      expect(json_body).to include("error" => "invalid_request", "path" => "data")
      json_post "/citizen/ombudsman/attachments", filename: "anexo-1.png", data: png_base64
      expect(json_body).to include("error" => "invalid_request", "path" => "content_type")
      expect(OmbudsmanAttachment.count).to eq(0)
    end

    it "exige a sessão (401) e o interruptor (403 feature_disabled)" do
      upload "/citizen/ombudsman/attachments"
      expect(response).to have_http_status(:unauthorized)

      sign_in_citizen
      Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      upload "/citizen/ombudsman/attachments"
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("feature_disabled")
    end

    it "o 21º upload na hora → 429 too_many_requests; é por sessão" do
      memory_cache!
      sign_in_citizen
      20.times do
        upload "/citizen/ombudsman/attachments"
        expect(response).to have_http_status(:created)
      end
      upload "/citizen/ombudsman/attachments"
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body).to eq("error" => "too_many_requests")

      sign_in_citizen("+5541991112222")
      upload "/citizen/ombudsman/attachments"
      expect(response).to have_http_status(:created)
    end
  end

  describe "POST /ombudsman/attachments" do
    it "o técnico sobe: 201 só com o id; dono = o usuário" do
      sign_in_as(technician)
      upload "/ombudsman/attachments"
      expect(response).to have_http_status(:created)
      expect(json_body.keys).to eq([ "id" ])
      attachment = OmbudsmanAttachment.find(json_body["id"])
      expect(attachment).to have_attributes(uploaded_by: "staff", uploaded_by_user_id: technician.id, citizen_session_id: nil,
                                            ombudsman_manifestation_id: nil)
      expect(attachment.exam_file).to have_attributes(uploaded_by_user_id: technician.id, consumed_at: nil)
    end

    it "o ouvidor sobe; quem não é da ouvidoria → 403 missing_role; arquivo inválido → 422 invalid_file" do
      sign_in_as(ouvidor)
      upload "/ombudsman/attachments"
      expect(response).to have_http_status(:created)
      upload "/ombudsman/attachments", data: Base64.strict_encode64("texto"), content_type: "application/pdf"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["error"]).to eq("invalid_file")
      upload "/ombudsman/attachments", filename: "a/b.png"
      expect(json_body).to include("error" => "invalid_request", "path" => "filename")

      sign_in_as(responder!(department!))
      upload "/ombudsman/attachments"
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
    end

    it "o 21º upload na hora → 429 too_many_requests" do
      memory_cache!
      sign_in_as(technician)
      20.times { upload "/ombudsman/attachments" }
      expect(response).to have_http_status(:created)
      upload "/ombudsman/attachments"
      expect(response).to have_http_status(:too_many_requests)
      expect(json_body).to eq("error" => "too_many_requests")
    end
  end

  describe "Ombudsman::Attachments.link!" do
    let(:session) { CitizenSession.start!(phone: "+5541998765432").first }
    let(:manifestation) { raw_manifestation! }

    def orphan!(owner: session, **) = Ombudsman::Attachments.upload(data: png_base64, content_type: "image/png", filename: "anexo-1.png", **owner_args(owner)).payload.fetch(:attachment)
    def owner_args(owner) = owner.is_a?(User) ? { user: owner } : { citizen_session: owner }
    def link!(ids, owner: session, event: nil) = ApplicationRecord.transaction { Ombudsman::Attachments.link!(ids: ids, manifestation: manifestation, owner: owner, event: event) }

    it "liga na manifestação e consome o arquivo na mesma transação" do
      a, b = orphan!, orphan!
      result = link!([ a.id, b.id ])
      expect(result).to be_ok
      expect(result.payload[:attachments].map(&:id)).to contain_exactly(a.id, b.id)
      [ a, b ].each do |att|
        expect(att.reload.ombudsman_manifestation_id).to eq(manifestation.id)
        expect(att.exam_file.reload.consumed_at).to be_present
      end
    end

    it "com event: grava o complemento que trouxe o anexo" do
      event = OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "complement_received", actor: "citizen", data: {})
      a = orphan!
      expect(link!([ a.id ], event: event)).to be_ok
      expect(a.reload.event_id).to eq(event.id)
    end

    it "chamada direta fora de transação é atômica: falha no meio não consome nem liga nada" do
      a = orphan!
      ghost = Struct.new(:id, :ombudsman_manifestation_id).new(SecureRandom.uuid, manifestation.id)
      expect { Ombudsman::Attachments.link!(ids: [ a.id ], manifestation: manifestation, owner: session, event: ghost) }
        .to raise_error(ActiveRecord::InvalidForeignKey)
      expect(a.exam_file.reload.consumed_at).to be_nil
      expect(a.reload.ombudsman_manifestation_id).to be_nil
    end

    it "event de outra manifestação é erro de programação (ArgumentError), nada gravado" do
      a = orphan!
      foreign = OmbudsmanEvent.create!(ombudsman_manifestation: raw_manifestation!, kind: "complement_received", actor: "citizen", data: {})
      expect { link!([ a.id ], event: foreign) }.to raise_error(ArgumentError)
      expect(a.exam_file.reload.consumed_at).to be_nil
      expect(a.reload.ombudsman_manifestation_id).to be_nil
    end

    it "sem ids (nil ou lista vazia) não liga nada" do
      [ nil, [] ].each { |ids| expect(link!(ids).payload[:attachments]).to eq([]) }
    end

    it "recusa ids malformados, repetidos, inexistentes, de outro dono ou já ligados (invalid_request, nada gravado)" do
      mine = orphan!
      theirs = orphan!(owner: CitizenSession.start!(phone: "+5541991112222").first)
      staff_owned = orphan!(owner: technician)
      linked = raw_attachment!(manifestation: raw_manifestation!)
      [ "x", mine.id, [ "x" ], [ mine.id, mine.id ], [ SecureRandom.uuid ], [ theirs.id ], [ mine.id, theirs.id ],
        [ staff_owned.id ], [ linked.id ], { "0" => mine.id } ].each do |ids|
        result = link!(ids)
        expect(result.reason).to eq(:invalid_request), "esperava invalid_request para #{ids.inspect}"
        expect(result.details[:path]).to eq("attachment_ids")
      end
      expect(link!(mine.id).reason).to eq(:invalid_request)
      expect(mine.reload.ombudsman_manifestation_id).to be_nil
      expect(mine.exam_file.reload.consumed_at).to be_nil
    end

    it "o usuário só liga o que subiu" do
      a = orphan!(owner: technician)
      expect(link!([ a.id ], owner: ouvidor).reason).to eq(:invalid_request)
      expect(link!([ a.id ], owner: technician)).to be_ok
    end

    it "arquivo já consumido (sem manifestação) não liga" do
      a = orphan!
      a.exam_file.update!(consumed_at: Time.current)
      expect(link!([ a.id ]).reason).to eq(:invalid_request)
    end

    it "mais de MAX_ATTACHMENTS → too_many_attachments" do
      ids = Array.new(Ombudsman::Catalog::MAX_ATTACHMENTS + 1) { orphan!.id }
      expect(link!(ids).reason).to eq(:too_many_attachments)
      expect(link!(ids.first(Ombudsman::Catalog::MAX_ATTACHMENTS))).to be_ok
    end
  end

  describe "POST /ombudsman/attachments/:id/link e GET /ombudsman/files/:token" do
    let(:identified) { raw_manifestation!(citizen: web_citizen!) }
    let(:preserved) { raw_manifestation!(citizen: web_citizen!, identification_mode: "preserved") }
    let(:anonymous) { raw_manifestation!(kind: "report", identification_mode: "anonymous", channel: "web", created_by_user: nil) }

    def linked!(manifestation, filename: "#{marker}.png") = raw_attachment!(manifestation: manifestation, filename: filename)

    it "o técnico abre o anexo de manifestação identificada: URL curta e os bytes inline, sem trilha de identidade" do
      att = linked!(identified)
      sign_in_as(technician)
      token = nil
      log = capture_log do
        json_post "/ombudsman/attachments/#{att.id}/link", {}
        token = json_body["url"].split("/").last
        expect(response).to have_http_status(:ok)
        expect(json_body.keys).to contain_exactly("url", "expires_at")
        expect(json_body["url"]).to match(%r{\A/ombudsman/files/[^/]+\z})
        expect(Time.zone.parse(json_body["expires_at"])).to be_within(5.seconds).of(5.minutes.from_now)
        get json_body["url"]
      end
      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(ombudsman_png)
      expect(response.media_type).to eq("image/png")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.headers["Content-Disposition"]).to eq(%(inline; filename="anexo-#{att.id[0, 8]}.png"; filename*=UTF-8''anexo-#{att.id[0, 8]}.png))
      expect(response.headers.to_h.to_s).not_to include(marker)
      expect(log).not_to include(marker)
      expect(log).not_to include(token)
      expect(log).to include("/ombudsman/files/[FILTERED]")
      expect(OmbudsmanIdentityAccess.count).to eq(0)
      expect(DomainEvent.where(name: "ombudsman.identity_viewed")).to be_empty
    end

    it "o ouvidor também abre o de manifestação identificada, sem justificativa" do
      att = linked!(identified)
      sign_in_as(ouvidor)
      json_post "/ombudsman/attachments/#{att.id}/link", {}
      expect(response).to have_http_status(:ok)
    end

    %w[preserved anonymous].each do |mode|
      it "#{mode}: o técnico → 403 missing_role e nenhuma linha de acesso" do
        att = linked!(send(mode))
        sign_in_as(technician)
        json_post "/ombudsman/attachments/#{att.id}/link", justification: "Preciso conferir o documento anexado."
        expect(response).to have_http_status(:forbidden)
        expect(json_body["error"]).to eq("missing_role")
        expect(OmbudsmanIdentityAccess.count).to eq(0)
      end

      it "#{mode}: o ouvidor sem justificativa → 422 path justification; com ela → URL, um acesso e o evento só com ids" do
        manifestation = send(mode)
        att = linked!(manifestation)
        sign_in_as(ouvidor)
        [ {}, { justification: "curta" }, { justification: "x" * 501 }, { justification: 12 }, { justification: "   " } ].each do |body|
          json_post "/ombudsman/attachments/#{att.id}/link", body
          expect(response).to have_http_status(:unprocessable_content)
          expect(json_body).to include("error" => "invalid_request", "path" => "justification")
        end
        expect(OmbudsmanIdentityAccess.count).to eq(0)

        text = "Conferir a identidade de #{marker} no documento."
        log = capture_log { json_post "/ombudsman/attachments/#{att.id}/link", justification: "  #{text}  " }
        expect(response).to have_http_status(:ok)
        expect(json_body["url"]).to start_with("/ombudsman/files/")
        access = OmbudsmanIdentityAccess.sole
        expect(access).to have_attributes(scope: "attachment", exam_file_id: att.exam_file_id, user_id: ouvidor.id,
                                          ombudsman_manifestation_id: manifestation.id, justification: text)
        event = DomainEvent.where(name: "ombudsman.identity_viewed").sole
        expect(event.payload).to eq("manifestation_id" => manifestation.id, "access_id" => access.id)
        expect(log).not_to include(marker)
        expect(DomainEvent.pluck(:payload).to_json).not_to include(marker)

        get json_body["url"]
        expect(response).to have_http_status(:ok)
        expect(response.body.b).to eq(ombudsman_png)
      end
    end

    it "anexo órfão, id inexistente ou malformado → 404; quem não é da ouvidoria → 403" do
      orphan = raw_attachment!
      sign_in_as(ouvidor)
      [ orphan.id, SecureRandom.uuid, "x" ].each do |id|
        json_post "/ombudsman/attachments/#{id}/link", {}
        expect(response).to have_http_status(:not_found)
      end
      sign_in_as(responder!(department!))
      json_post "/ombudsman/attachments/#{linked!(identified).id}/link", {}
      expect(response).to have_http_status(:forbidden)
    end

    it "o token vencido → 410 link_expired; falso, de outro usuário ou de outro tipo de arquivo → 404" do
      att = linked!(identified)
      sign_in_as(technician)
      json_post "/ombudsman/attachments/#{att.id}/link", {}
      url = json_body["url"]

      travel_to(6.minutes.from_now) do
        get url
        expect(response).to have_http_status(:gone)
        expect(json_body["error"]).to eq("link_expired")
      end

      get "/ombudsman/files/falso"
      expect(response).to have_http_status(:not_found)
      get "/ombudsman/files/#{url.split('/').last}x"
      expect(response).to have_http_status(:not_found)

      exam_file = ExamFile.create!(content_type: "image/png", byte_size: 1, sha256: "a" * 64, data: png_base64, purpose: "tfd_accountability")
      get Exams::Files.url_for(exam_file, user: technician).sub("/exams/", "/ombudsman/")
      expect(response).to have_http_status(:not_found)
      get Tfd::Files.url_for(exam_file, user: technician).sub("/tfd/", "/ombudsman/")
      expect(response).to have_http_status(:not_found)

      sign_in_as(ouvidor)
      get url
      expect(response).to have_http_status(:not_found)
    end

    it "token de arquivo da ouvidoria que ainda é órfão → 404" do
      orphan = raw_attachment!
      sign_in_as(technician)
      get Ombudsman::Files.url_for(orphan.exam_file_id, user: technician)
      expect(response).to have_http_status(:not_found)
    end

    it "sem sessão → 401; o interruptor desligado → 403 feature_disabled" do
      att = linked!(identified)
      sign_in_as(technician)
      json_post "/ombudsman/attachments/#{att.id}/link", {}
      url = json_body["url"]
      Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      get url
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("feature_disabled")
    end
  end

  describe "limpeza do órfão" do
    it "o órfão de 25 h some pelo Exams::DailyJob sem erro (cascata); o ligado fica" do
      orphan = travel_to(25.hours.ago) { raw_attachment! }
      linked = travel_to(30.hours.ago) { raw_attachment!(manifestation: raw_manifestation!) }
      fresh = raw_attachment!

      expect { Exams::DailyJob.perform_now }.not_to raise_error
      expect(OmbudsmanAttachment.where(id: orphan.id)).to be_empty
      expect(ExamFile.where(id: orphan.exam_file_id)).to be_empty
      expect(OmbudsmanAttachment.where(id: [ linked.id, fresh.id ]).count).to eq(2)
    end
  end
end

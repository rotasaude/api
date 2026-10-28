require "rails_helper"

# Módulo 26a, Task 8 (ADR 0044; contrato §4, §13 G1, G3, G5, G7; plano do api,
# Desvios 3–6, Review Focus 1 e 4): autorizar um pedido `pending` numa oferta
# do mês corrente, com cota, cor resultante, motivo de pular a fila e, na rede
# própria, o pedido de agendamento `regulated` do 17.
RSpec.describe CareRegulation::Authorize do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  before do
    travel_to now
    regulation_city!
  end

  let(:regulator) { care_regulator! }
  let(:contracted) { external_provider! }
  let(:offer) { offer!(provider: contracted) }
  let(:specialist_unit) { create_unit("Centro de Especialidades #{SecureRandom.hex(2)}") }
  let(:own_offer) { offer!(provider: own_provider!(specialist_unit)) }

  # Pedido promovido `days` dias antes de agora (meio-dia), pelo caminho real.
  # travel_to sem bloco: o bloco aninhado devolveria o relógio real.
  def aged!(days, color, **over)
    travel_to(now.change(hour: 12) - days.days)
    regulation_request!(suggested_color: color, **over)
  ensure
    travel_to now
  end

  def authorize(request, offer:, version: request.version, **over)
    described_class.call(request: request, offer_id: offer.id, version: version, by: regulator, **over)
  end

  def used(offer) = CareRegulation::Quota.used([ offer.id ]).fetch(offer.id)
  def raw_skip_reason(authorization)
    ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql([ "SELECT skip_reason FROM regulation_authorizations WHERE id = ?", authorization.id ])
    )
  end

  it "autoriza na oferta externa com saldo: authorized, autorização contratada, a cota cai 1 e o evento só com ids" do
    request = aged!(3, "yellow")
    expect(CareRegulation::Quota.available(offer, used: used(offer))).to eq(5)
    result = authorize(request, offer: offer)
    expect(result).to be_ok
    authorization = result.payload.fetch(:authorization)
    expect(result.payload[:appointment_request]).to be_nil
    expect(request.reload).to have_attributes(status: "authorized", version: 3, color: nil, appointment_request_id: nil,
                                              due_on: Date.new(2026, 10, 25) + 30)
    expect(authorization).to have_attributes(regulation_request_id: request.id, care_offer_id: offer.id, month: Date.new(2026, 10, 1),
                                             authorized_by_user_id: regulator.id, skip_reason: nil, released_at: nil)
    expect(authorization.care_offer.care_provider.kind).to eq("contracted")
    expect(CareRegulation::Quota.available(offer, used: used(offer))).to eq(4)
    expect(request.events.map(&:status)).to eq(%w[pending authorized])
    expect(request.events.last).to have_attributes(by_user_id: regulator.id, reason: nil)
    expect(DomainEvent.where(name: "regulation_request.authorized").map(&:payload))
      .to eq([ { "regulation_request_id" => request.id, "user_id" => regulator.id } ])
  end

  describe "cor resultante (G7)" do
    it "amarelo → vermelho sem motivo: color_reason_required e nada muda; com motivo, due_on = data do pedido + 7" do
      request = aged!(3, "yellow")
      expect(authorize(request, offer: offer, color: "red").reason).to eq(:color_reason_required)
      expect(request.reload).to have_attributes(status: "pending", version: 2)
      expect(used(offer)).to eq(0)

      result = authorize(request, offer: offer, color: "red", color_reason: "Piora dos sintomas na última semana")
      expect(result).to be_ok
      expect(request.reload).to have_attributes(status: "authorized", color: "red", due_on: Date.new(2026, 10, 25) + 7)
      expect(request.color_reason).to eq("Piora dos sintomas na última semana")
    end

    it "confirmar a mesma cor efetiva não exige motivo e não mexe no prazo" do
      request = aged!(3, "yellow")
      due = request.due_on
      expect(authorize(request, offer: offer, color: "yellow")).to be_ok
      expect(request.reload).to have_attributes(color: "yellow", due_on: due, color_reason: nil)
    end

    it "cor sem mudança: o color_reason enviado é ignorado (nem gravado nem devolvido)" do
      request = aged!(3, "yellow")
      expect(authorize(request, offer: offer, color: "yellow", color_reason: "Motivo enviado sem mudança de cor")).to be_ok
      expect(request.reload).to have_attributes(color: "yellow", color_reason: nil)
      expect(authorize(aged!(2, "red", target_code: "225250"), offer: offer!(provider: contracted, target_code: "225250"),
                       color_reason: "Motivo sem cor nenhuma enviada")).to be_ok
      expect(RegulationRequest.where(target_code: "225250").sole.color_reason).to be_nil
    end

    it "o prazo recalculado lê a tabela de prazos da hora e conta da data original do pedido" do
      request = aged!(40, "green")
      RegulationRiskDeadline.find("yellow").update!(days: 20)
      expect(authorize(request, offer: offer, color: "yellow", color_reason: "Reavaliação do caso pelo regulador")).to be_ok
      expect(request.reload.due_on).to eq(Date.new(2026, 9, 18) + 20)
    end
  end

  describe "motivo para pular a fila (Desvio 4, G5)" do
    it "pending mais antigo do mesmo alvo com cor igual → skip_reason_required sem detalhe; com motivo grava cifrado" do
      aged!(10, "yellow")
      request = aged!(3, "yellow")
      refused = authorize(request, offer: offer)
      expect([ refused.reason, refused.details ]).to eq([ :skip_reason_required, {} ])
      expect(used(offer)).to eq(0)

      result = authorize(request, offer: offer, skip_reason: "Paciente com cirurgia já marcada no prestador")
      expect(result).to be_ok
      authorization = result.payload.fetch(:authorization)
      expect(authorization.reload.skip_reason).to eq("Paciente com cirurgia já marcada no prestador")
      expect(raw_skip_reason(authorization)).to be_present
      expect(raw_skip_reason(authorization)).not_to include("cirurgia")
    end

    it "sem ninguém à frente, o skip_reason enviado é ignorado: a autorização não diz 'fora da ordem'" do
      older = aged!(10, "yellow")
      request = aged!(3, "yellow")
      expect(authorize(request, offer: offer).reason).to eq(:skip_reason_required)
      # Outro regulador autoriza o mais antigo entre o 422 e o reenvio.
      expect(authorize(older, offer: offer)).to be_ok
      result = authorize(request.reload, offer: offer, skip_reason: "Paciente com cirurgia já marcada no prestador")
      expect(result).to be_ok
      authorization = result.payload.fetch(:authorization).reload
      expect(authorization.skip_reason).to be_nil
      expect(raw_skip_reason(authorization)).to be_nil
    end

    it "o mais antigo mais grave (vermelho) também exige; o menos grave (verde) não" do
      aged!(10, "red")
      request = aged!(3, "yellow")
      expect(authorize(request, offer: offer).reason).to eq(:skip_reason_required)

      other_target = aged!(10, "green", target_code: "225250")
      green_older = aged!(9, "green", target_code: "225250")
      request2 = aged!(2, "yellow", target_code: "225250")
      offer2 = offer!(provider: contracted, target_code: "225250")
      expect([ other_target, green_older ].map(&:status)).to eq(%w[pending pending])
      expect(authorize(request2, offer: offer2)).to be_ok
    end

    it "vale a cor RESULTANTE: pedido verde atrás de amarelo exige; confirmado vermelho, não" do
      aged!(10, "yellow")
      request = aged!(3, "green")
      expect(authorize(request, offer: offer).reason).to eq(:skip_reason_required)
      expect(authorize(request, offer: offer, color: "red", color_reason: "Achado novo no exame de imagem")).to be_ok
    end

    it "mesmo requested_at: o de id menor é o mais antigo" do
      travel_to(now.change(hour: 12) - 5.days)
      pair = [ regulation_request!(suggested_color: "yellow"), regulation_request!(suggested_color: "yellow") ].sort_by(&:id)
      travel_to now
      expect(pair.map(&:requested_at).uniq.size).to eq(1)
      expect(authorize(pair.last, offer: offer).reason).to eq(:skip_reason_required)
      expect(authorize(pair.first, offer: offer)).to be_ok
    end

    it "returned, external e outro alvo mais antigos não contam" do
      returned = aged!(10, "red")
      CareRegulation::Transition.call(request: returned.lock!, to: "returned", by: regulator, reason: "Faltam os exames prévios do pedido",
                                      version: returned.version)
      aged!(9, "red", status: "external")
      aged!(8, "red", target_code: "225250")
      request = aged!(3, "yellow")
      expect(authorize(request, offer: offer)).to be_ok
    end
  end

  describe "oferta autorizável (Desvio 3, G1)" do
    it "outro alvo, outro mês, prestador inativo, própria com unidade inativa ou id desconhecido → invalid_offer" do
      request = aged!(3, "yellow")
      other_target = offer!(provider: contracted, target_code: "225250")
      other_type = offer!(provider: contracted, target_type: "procedure", target_code: "0301010072")
      next_month = offer!(provider: contracted, month: Date.new(2026, 11, 1))
      last_month = offer!(provider: contracted, month: Date.new(2026, 9, 1))
      inactive = offer!(provider: external_provider!(kind: "consortium")).tap { |o| o.care_provider.update!(active: false) }
      closed_unit = create_unit("Especialidades Fechada #{SecureRandom.hex(2)}")
      closed_own = offer!(provider: own_provider!(closed_unit))
      HealthUnit.where(id: closed_unit.id).update_all(active: false)

      [ other_target, other_type, next_month, last_month, inactive, closed_own ].each do |bad|
        expect(authorize(request, offer: bad).reason).to eq(:invalid_offer)
      end
      expect(described_class.call(request: request, offer_id: SecureRandom.uuid, version: 2, by: regulator).reason).to eq(:invalid_offer)
      expect(request.reload).to have_attributes(status: "pending", version: 2)
      expect(RegulationAuthorization.count).to eq(0)
    end

    it "Review Focus 1: 31/10 às 23:30 em São Paulo (01/11 em UTC) — outubro autoriza, novembro é invalid_offer" do
      first = aged!(5, "yellow")
      second = aged!(4, "yellow", target_code: "225250")
      travel_to Time.utc(2026, 11, 1, 2, 30)
      Time.use_zone("America/Sao_Paulo") do
        expect(Time.zone.today).to eq(Date.new(2026, 10, 31))
        october = offer!(provider: contracted, month: Date.new(2026, 10, 1), quantity: 1)
        november = offer!(provider: contracted, target_code: "225250", month: Date.new(2026, 11, 1))
        result = authorize(first, offer: october)
        expect(result).to be_ok
        expect(result.payload.fetch(:authorization).month).to eq(Date.new(2026, 10, 1))
        expect(used(october)).to eq(1)
        expect(authorize(second, offer: november).reason).to eq(:invalid_offer)
        expect(second.reload.status).to eq("pending")
      end
    end
  end

  describe "cota" do
    it "sem saldo → quota_exhausted e nada gravado; oferta com quantidade 0 também" do
      full = offer!(provider: contracted, quantity: 1)
      expect(authorize(aged!(10, "red"), offer: full)).to be_ok
      request = aged!(3, "yellow")
      expect(authorize(request, offer: full).reason).to eq(:quota_exhausted)
      expect(used(full)).to eq(1)
      expect(request.reload).to have_attributes(status: "pending", version: 2)

      empty = offer!(provider: external_provider!(kind: "ppi"), quantity: 0)
      expect(authorize(request, offer: empty).reason).to eq(:quota_exhausted)
    end
  end

  describe "versão e situação" do
    it "version velha → stale_version e nada muda" do
      request = aged!(3, "yellow")
      expect(authorize(request, offer: offer, version: 1).reason).to eq(:stale_version)
      expect(request.reload).to have_attributes(status: "pending", version: 2)
      expect(RegulationAuthorization.count).to eq(0)
    end

    it "returned, external (regulado pelo estado) ou já autorizado → invalid_transition" do
      returned = aged!(3, "yellow")
      CareRegulation::Transition.call(request: returned.lock!, to: "returned", by: regulator, reason: "Faltam os exames prévios do pedido",
                                      version: returned.version)
      external = aged!(3, "yellow", status: "external")
      authorized = aged!(4, "yellow", target_code: "225250")
      expect(authorize(authorized, offer: offer!(provider: contracted, target_code: "225250"))).to be_ok

      expect(authorize(returned.reload, offer: offer).reason).to eq(:invalid_transition)
      expect(authorize(external, offer: offer).reason).to eq(:invalid_transition)
      expect(authorize(authorized.reload, offer: offer!(provider: external_provider!, target_code: "225250")).reason).to eq(:invalid_transition)
    end
  end

  describe "entrada" do
    it "cor fora da lista, motivos fora de 10..500, versão não inteira ou oferta sem uuid → invalid_request com path" do
      request = aged!(3, "yellow")
      cases = {
        { color: "purple" } => "color",
        { color: "red", color_reason: "curto" } => "color_reason",
        { color: "red", color_reason: "x" * 501 } => "color_reason",
        { skip_reason: "         curto      " } => "skip_reason",
        { skip_reason: 123 } => "skip_reason"
      }
      cases.each do |over, path|
        result = authorize(request, offer: offer, **over)
        expect([ result.reason, result.details ]).to eq([ :invalid_request, { path: path } ])
      end
      expect(authorize(request, offer: offer, version: "2").details).to eq(path: "version")
      expect(described_class.call(request: request, offer_id: "abc", version: 2, by: regulator).details).to eq(path: "offer_id")
      expect(described_class.call(request: request, offer_id: nil, version: 2, by: regulator).details).to eq(path: "offer_id")
      expect(RegulationAuthorization.count).to eq(0)
    end

    it "motivo com espaços nas pontas é gravado sem eles" do
      request = aged!(3, "yellow")
      expect(authorize(request, offer: offer, color: "red", color_reason: "  Piora dos sintomas na semana  ")).to be_ok
      expect(request.reload.color_reason).to eq("Piora dos sintomas na semana")
    end
  end

  describe "rede própria (Desvio 6, G3)" do
    it "cria o pedido de agendamento regulated na unidade do prestador, prioridade alta para vermelho, e o pedido aponta para ele" do
      request = aged!(3, "red")
      citizen = Citizen.find_by!(patient_id: request.patient_id)
      result = authorize(request, offer: own_offer)
      expect(result).to be_ok
      appointment = result.payload.fetch(:appointment_request)
      expect(appointment).to have_attributes(kind: "regulated", origin_regulation_request_id: request.id, citizen_id: citizen.id,
                                             origin_unit_id: request.requester_unit_id, target_unit_id: specialist_unit.id,
                                             appointment_type_key: "consulta_medica", priority: "priority", status: "open",
                                             due_on: request.reload.due_on)
      expect(appointment.origin).to eq("regulation")
      expect(request).to have_attributes(status: "authorized", appointment_request_id: appointment.id)
      expect(DomainEvent.where(name: "appointment_request.created").map(&:payload))
        .to eq([ { "appointment_request_id" => appointment.id, "regulation_request_id" => request.id, "target_unit_id" => specialist_unit.id,
                   "kind" => "regulated", "user_id" => regulator.id } ])
    end

    it "odontologia (2232*) → consulta_odontologica; amarelo → routine" do
      request = aged!(3, "yellow", target_code: "223212")
      result = authorize(request, offer: offer!(provider: own_provider!(specialist_unit), target_code: "223212"))
      expect(result).to be_ok
      expect(result.payload.fetch(:appointment_request)).to have_attributes(appointment_type_key: "consulta_odontologica", priority: "routine")
    end

    it "a cor confirmada vermelha leva a prioridade e o prazo recalculado ao pedido de agendamento" do
      request = aged!(3, "yellow")
      result = authorize(request, offer: own_offer, color: "red", color_reason: "Piora dos sintomas na última semana")
      expect(result.payload.fetch(:appointment_request)).to have_attributes(priority: "priority", due_on: Date.new(2026, 10, 25) + 7)
    end

    it "Review Focus 4: validação do único par revogada → citizen_not_verified, nada gravado, cota intacta" do
      request = aged!(3, "yellow")
      citizen = Citizen.find_by!(patient_id: request.patient_id)
      revoked = Citizens::RevokeVerification.call(verification: citizen.active_verification, reason: "Documento de outra pessoa",
                                                  by: staff_with("adm-revoga-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin"))
      expect(revoked).to be_ok
      own_offer
      authorizations = RegulationAuthorization.count
      appointments = AppointmentRequest.count

      result = authorize(request, offer: own_offer)
      expect(result.reason).to eq(:citizen_not_verified)
      expect(RegulationAuthorization.count).to eq(authorizations)
      expect(AppointmentRequest.count).to eq(appointments)
      expect(used(own_offer)).to eq(0)
      expect(request.reload).to have_attributes(status: "pending", version: 2, appointment_request_id: nil)
      expect(DomainEvent.where(name: %w[regulation_request.authorized appointment_request.created])).to be_empty

      # O mesmo paciente segue autorizável numa oferta externa (não precisa de par).
      expect(authorize(request, offer: offer)).to be_ok
    end
  end
end

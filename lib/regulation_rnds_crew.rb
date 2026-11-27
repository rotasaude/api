require "zlib"
require "openssl"
require "base64"
require_relative "professional_crew"
require_relative "regulation_crew"
require_relative "vaccination_crew"

# Semente de dev do módulo 26c (envio da regulação à RNDS), para a prova no
# navegador contra o simulado (fake-rnds). Roda depois do RegulationCrew (os
# dez pedidos da 26a) e só em Curitiba. Tudo pelos comandos do app
# (Integrations::SetCredential, Platform::Features.set!,
# Regulation::SaveRndsSettings, CareRegulation::SaveOffer/SaveProvider e os
# mesmos caminhos de pedido do RegulationCrew); as exceções estão marcadas.
#
#   o quê                                     onde / como
#   credencial `rnds_regulation`              certificado de teste autoassinado (o mesmo do
#                                             VaccinationCrew), requester_id 12345, CNS de dev
#                                             do responsável; o simulado aceita qualquer um
#   interruptores                             rnds_regulation e rnds_mock LIGADOS
#   configurações                             cardiologia -> SIGTAP 0301010072; envio dos
#                                             regulados pelo estado LIGADO (o padrão é desligado)
#   performer_cbo numa oferta                 a do PPI (endoscopia)
#   default_performer_cbo num prestador       a Clínica de Olhos Araucária
#   CNES da UBS Jardim das Flores             só se estiver em branco (mesma conta das outras
#                                             sementes): sem ele nenhum pedido sai
#
# Pedidos novos, um por motivo de parado alcançável (RndsCatalog::BLOCK_REASONS);
# cada pessoa tem um só pedido. Dois motivos ficam sem pedido: `missing_priority`
# (o banco não deixa: suggested_color é NOT NULL) e `patient_without_cpf_or_cns`
# (a identidade do paciente nunca muda, e só o provisório da UPA, módulo 32, nasce
# sem CPF e CNS: um pedido dele exige a consulta de urgência, fora desta semente).
#
#   n   motivo                              como cai nele
#   11  missing_diagnosis                   cardiologia pendente; CID-10 e CIAP-2 retirados (*)
#   12  requester_unit_without_cnes         oftalmologia pendente pedida na UBS Vila Esperança,
#                                           que não tem CNES (a médica ganha o vínculo ali)
#   14  specialty_without_sigtap            ginecologia pendente; o mapa de SIGTAP guarda um código
#                                           que a competência corrente não regula (*)
#   15  performer_without_cnes              oftalmologia agendada na rede própria, na Policlínica
#                                           Municipal do Cajuru, que perdeu o CNES (*)
#   16  performer_cbo_missing               exérese (0401010074, grupo 04) agendada no consórcio,
#                                           sem performer_cbo na oferta nem default no prestador
#   17  external_absence_without_schedule   oftalmologia regulada pelo estado, com uma falta
#                                           gravada sem as colunas da Q24 (o formato de antes do
#                                           deploy; INSERT, o andamento nunca é alterado)
#
#   (*) o app não deixa chegar aí pelos comandos: dado de antes da regra (11), mapa de
#       SIGTAP de uma competência anterior (14), CNES retirado depois do cadastro (15). A
#       semente grava a coluna direto e o diz aqui. O 15 também passa para `scheduled` pelo
#       Transition, como o AppointmentSync faz (sem horário na agenda).
#
#   Atenção na prova (14): a tela de configurações confere o mapa inteiro a cada
#   salvar, então, com a ginecologia (225250) no mapa, TODO salvar volta 422
#   `invalid_sigtap` com `path` `specialty_sigtap.225250`. Para salvar outra coisa,
#   tire essa entrada do mapa (ou troque o código por um regulável, como o
#   0301010072) no mesmo salvar: é também o que solta o pedido 14 na próxima rodada.
#
# Os marcadores do simulado ficam em dois pedidos válidos da 26a (3 e 4, só
# pendentes): `bundle_identifier` RECUSA-<uuid> (422 EHR-ERR999) e TIMEOUT-<uuid>
# (o simulado grava e não responde). O simulado dorme a cada POST de um
# identificador TIMEOUT (a espera do compose), então o pedido 4 trava cada rodada
# de envio nesse tempo. Só dev: nenhum segredo de staging ou de produção.
#
# Os motivos são conferidos aqui pela mesma RndsValidation do envio, sobre os
# fatos do documento que sairia; quem passa a `blocked` na tela é o
# RndsDeliverJob. Idempotente: cada peça é achada por chave estável antes de criar.
class RegulationRndsCrew
  DEV_MAINTAINER = "dev@local".freeze
  REQUESTER_ID = "12345".freeze
  FEATURES = %w[rnds_regulation rnds_mock].freeze
  MAPPED_SPECIALTY = RegulationCrew::CARDIOLOGY
  MAPPED_SIGTAP = "0301010072".freeze
  GYNECOLOGY = "225250".freeze
  # SIGTAP real (consulta especializada de nível superior) fora do recorte de dev: o mapa de uma competência anterior.
  STALE_SIGTAP = "0301010048".freeze
  EXCISION = "0401010074".freeze
  OFFER_PERFORMER_CBO = "225210".freeze
  PROVIDER_PERFORMER_CBO = RegulationCrew::OPHTHALMOLOGY
  SECOND_UNIT = "UBS Vila Esperança".freeze
  POLYCLINIC = "Policlínica Municipal do Cajuru".freeze
  # Só desta semente (o 92222 é do ClinicalRecordCrew).
  PHONE_PREFIX = "99222".freeze
  MARKER_NAMESPACE = "6f1d3c52-8a0e-4b7a-9f3e-2c5d7e1b4a60".freeze
  # Pedidos da 26a que carregam os marcadores do simulado.
  REFUSED_N = 3
  TIMEOUT_N = 4

  PEOPLE = {
    rnds_diagnostico: { phone: 1, name: "Elisabete Maria Tomaszewski", mother: "Cecília Tomaszewski", birth: "1963-06-12", sex: "female" },
    rnds_unidade: { phone: 2, name: "Jorge Luiz Ostrowski", mother: "Helena Ostrowski", birth: "1957-01-29", sex: "male" },
    rnds_sigtap: { phone: 4, name: "Débora Cristina Wagner", mother: "Ilse Wagner", birth: "1987-04-21", sex: "female" },
    rnds_executante: { phone: 5, name: "Nelson Antunes Pietrowski", mother: "Zuleica Antunes", birth: "1952-10-17", sex: "male" },
    rnds_cbo: { phone: 6, name: "Rogério Batista Lewandowski", mother: "Marta Batista", birth: "1978-12-03", sex: "male" },
    rnds_falta: { phone: 7, name: "Sônia Regina Grabowski", mother: "Alzira Grabowski", birth: "1960-02-26", sex: "female" }
  }.transform_values { |person| person.merge(phone_prefix: PHONE_PREFIX) }.freeze

  def self.pending_request(n, who, code, cid10, color, days_ago, justification, **over)
    { n: n, who: who, person: PEOPLE.fetch(who), type: "specialty", code: code, cid10: cid10, color: color, days_ago: days_ago, to: "pending",
      justification: justification }.merge(over)
  end
  private_class_method :pending_request

  SCENARIOS = {
    missing_diagnosis: pending_request(11, :rnds_diagnostico, RegulationCrew::CARDIOLOGY, "I10", "yellow", 4,
                                       "Hipertensão em acompanhamento com pressão acima da meta nas últimas consultas; solicito avaliação cardiológica."),
    requester_unit_without_cnes: pending_request(12, :rnds_unidade, RegulationCrew::OPHTHALMOLOGY, "H25", "green", 6,
                                                 "Baixa de acuidade visual progressiva no olho esquerdo; opacidade de cristalino à oftalmoscopia.",
                                                 unit: SECOND_UNIT),
    specialty_without_sigtap: pending_request(14, :rnds_sigtap, GYNECOLOGY, "I10", "green", 2,
                                              "Sangramento uterino anormal há três ciclos, sem resposta ao tratamento clínico inicial; solicito avaliação ginecológica."),
    performer_without_cnes: pending_request(15, :rnds_executante, RegulationCrew::OPHTHALMOLOGY, "H40", "yellow", 9,
                                            "Pressão intraocular elevada com escavação aumentada do disco óptico; história familiar de glaucoma.",
                                            to: "authorized", offer: :polyclinic),
    performer_cbo_missing: pending_request(16, :rnds_cbo, EXCISION, "I10", "green", 8,
                                           "Nódulo subcutâneo de crescimento lento no dorso, sugestivo de lipoma, com desconforto ao uso de mochila; solicito exérese.",
                                           type: "procedure", to: "scheduled", offer: :excision, schedule_in: 5.days),
    external_absence: pending_request(17, :rnds_falta, RegulationCrew::OPHTHALMOLOGY, "H40", "blue", 20,
                                      "Rastreio de glaucoma por história familiar, regulado pelo estado; faltou à consulta marcada.",
                                      to: "external", state_regulated: true, external: { system: "sisreg", number: "202611200017" })
  }.freeze

  # motivo (RndsCatalog::BLOCK_REASONS) => pedido que cai nele.
  BLOCKED = {
    "missing_diagnosis" => :missing_diagnosis,
    "requester_unit_without_cnes" => :requester_unit_without_cnes,
    "performer_without_cnes" => :performer_without_cnes,
    "performer_cbo_missing" => :performer_cbo_missing,
    "specialty_without_sigtap" => :specialty_without_sigtap,
    "external_absence_without_schedule" => :external_absence
  }.freeze

  class << self
    def seed_current_city(slug:, ddd: "41")
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] regulação rnds: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptores não ligados"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end
      return off("desligado (sem a regulação)") unless RegulationRequest.exists?

      RegulationCrew.send(:guard_month_start!)
      city = City.find(Current.city.id)
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      regulator = User.find_by!(email_address: "#{RegulationCrew::REGULATOR[:email_prefix]}@#{slug}.demo")
      doctor = User.find_by!(email_address: "profissional@#{slug}.demo")
      unit = ensure_unit_cnes!(slug)

      credential!(admin, city, slug, unit)
      FEATURES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
      CityCatalog.reset_cache!
      providers = RegulationCrew.send(:providers!, admin)
      offers = RegulationCrew.send(:offers!, providers, admin)
      cbos!(providers, offers, admin)
      settings!(admin)
      polyclinic = polyclinic!(admin)
      offers = offers.merge(polyclinic: offer!(polyclinic, "specialty", RegulationCrew::OPHTHALMOLOGY, 3, admin),
                            excision: offer!(providers.fetch(:consortium), "procedure", EXCISION, 3, admin))
      second_unit_link!(doctor, admin)

      requests = scenarios!(slug, ddd, offers, regulator, doctor)
      markers!
      syncs!(requests)

      { switch: Regulation::RndsGate.usable?(city) ? "ligado (rnds_regulation, simulado)" : "ligado, não utilizável",
        requests: requests.size, blocked: blocked_counts(requests), markers: %w[RECUSA TIMEOUT] }
    end

    # Só dev: nada de segredo (nem o da credencial de dev) nas linhas.
    def summary_lines(result)
      head = "[seeds] regulação rnds #{result[:switch]}"
      return [ head ] unless result[:blocked]

      [ "#{head}; credencial rnds_regulation de dev (certificado de teste autoassinado)",
        "[seeds]               #{result[:requests]} pedidos novos; motivos de parado conferidos: #{result[:blocked].map { |reason, count| "#{reason} #{count}" }.join(', ')}",
        "[seeds]               sem pedido: missing_priority (suggested_color é NOT NULL) e patient_without_cpf_or_cns (só o provisório da UPA nasce assim)",
        "[seeds]               marcadores do simulado: pedidos 3 (RECUSA, 422 EHR-ERR999) e 4 (TIMEOUT: o simulado dorme a cada POST, a rodada espera esse tempo)",
        "[seeds]               o bloqueio na tela vem do envio (RndsDeliverJob) rodando no worker",
        "[seeds]               configurações: a ginecologia (#{GYNECOLOGY}) fica no mapa com um SIGTAP vencido (pedido 14); todo salvar " \
        "da tela volta invalid_sigtap em specialty_sigtap.#{GYNECOLOGY} até essa entrada sair do mapa (remova ou troque o código ao salvar)" ]
    end

    private

    def guard_environment!
      raise "semente da regulação rnds: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, requests: 0, blocked: nil, markers: [] }

    def check!(result, what)
      raise "semente da regulação rnds: #{what} recusado (#{result.reason} #{result.details})" if result.failure?

      result
    end

    def cnes_for(slug, name) = (Zlib.crc32("cnes:#{slug}:#{name}") % 9_000_000 + 1_000_000).to_s

    # --- unidade, credencial e interruptores --------------------------------

    # A UBS que pede os pedidos prontos: sem CNES nenhum documento passa.
    def ensure_unit_cnes!(slug)
      unit = HealthUnit.find_by!(name: RegulationCrew::UNIT)
      unit.update!(cnes: cnes_for(slug, unit.name)) if unit.cnes.blank?
      unit
    end

    # Uma só; a que já existe (trocada pela prova) fica como está.
    def credential!(admin, city, slug, unit)
      return if IntegrationCredential.exists?(kind: "rnds_regulation")

      secret = { "pfx_base64" => Base64.strict_encode64(VaccinationCrew.send(:test_pfx)), "pfx_password" => VaccinationCrew::CERTIFICATE_PASSWORD,
                 "requester_cnes" => unit.cnes, "requester_id" => REQUESTER_ID,
                 "responsible_cns" => Professionals::Cns.generate("#{slug}:regulation-rnds:responsible") }
      check!(Integrations::SetCredential.call(kind: "rnds_regulation", secret: secret, by: admin, city: city, environment: "production"),
             "credencial rnds_regulation")
    end

    # --- prestadores, ofertas e configurações -------------------------------

    def cbos!(providers, offers, admin)
      ppi = offers.fetch(:ppi)
      unless ppi.performer_cbo == OFFER_PERFORMER_CBO
        check!(CareRegulation::SaveOffer.call(attrs: { "performer_cbo" => OFFER_PERFORMER_CBO }, by: admin, offer: ppi), "performer_cbo da oferta")
      end
      contracted = providers.fetch(:contracted)
      return if contracted.default_performer_cbo == PROVIDER_PERFORMER_CBO

      check!(CareRegulation::SaveProvider.call(attrs: { "default_performer_cbo" => PROVIDER_PERFORMER_CBO }, by: admin, provider: contracted),
             "default_performer_cbo do prestador")
    end

    # Cardiologia mapeada e o envio dos regulados pelo estado ligado, pelo
    # comando. O código velho (14) entra depois, direto na coluna: o comando
    # recusa o que a competência não regula, e é isso que ele finge ter sido.
    def settings!(admin)
      current = RegulationRndsSetting.current
      mapped = current.specialty_sigtap.to_h.except(GYNECOLOGY).merge(MAPPED_SPECIALTY => MAPPED_SIGTAP)
      if mapped != current.specialty_sigtap.to_h.except(GYNECOLOGY) || !current.send_external
        saved = Regulation::SaveRndsSettings.call(
          attrs: { "expected_version" => current.version, "priority_by_color" => current.priority_by_color, "specialty_sigtap" => mapped,
                   "send_external" => true }, by: admin)
        check!(saved, "configurações do envio")
        current = RegulationRndsSetting.current
      end
      return if current.specialty_sigtap[GYNECOLOGY] == STALE_SIGTAP

      current.update_columns(specialty_sigtap: current.specialty_sigtap.to_h.merge(GYNECOLOGY => STALE_SIGTAP))
    end

    def polyclinic!(admin)
      unit = HealthUnit.find_or_create_by!(name: POLYCLINIC) do |new_unit|
        new_unit.kind = "other"
        new_unit.cnes = cnes_for("curitiba", POLYCLINIC)
      end
      CareProvider.find_by(name: POLYCLINIC) ||
        check!(CareRegulation::SaveProvider.call(attrs: { "name" => POLYCLINIC, "kind" => "own", "health_unit_id" => unit.id }, by: admin),
               "prestador #{POLYCLINIC}").payload.fetch(:provider)
    end

    def offer!(provider, type, code, quantity, admin)
      month = Time.zone.today.beginning_of_month
      CareOffer.find_by(care_provider_id: provider.id, target_type: type, target_code: code, month: month) ||
        check!(CareRegulation::SaveOffer.call(attrs: { "provider_id" => provider.id, "target_type" => type, "target_code" => code,
                                                       "month" => month.strftime("%Y-%m"), "quantity" => quantity }, by: admin),
               "oferta #{code}").payload.fetch(:offer)
    end

    # A médica da UBS Jardim das Flores também atende na Vila Esperança (que fica sem CNES).
    def second_unit_link!(doctor, admin)
      unit = HealthUnit.find_by!(name: SECOND_UNIT)
      ProfessionalCrew.send(:ensure_link, doctor.professional, unit, "225125", admin)
    end

    # --- pedidos --------------------------------------------------------------

    def scenarios!(slug, ddd, offers, regulator, doctor)
      clock = Time.current
      default_unit = HealthUnit.find_by!(name: RegulationCrew::UNIT)
      SCENARIOS.to_h do |key, spec|
        unit = spec[:unit] ? HealthUnit.find_by!(name: spec[:unit]) : default_unit
        request = RegulationCrew.send(:request!, slug, ddd, spec, unit, doctor, clock)
        RegulationCrew.send(:advance!, request, spec, regulator, offers, clock)
        [ key, finish!(key, request.reload, regulator) ]
      end
    end

    # O que o app não deixa chegar pelos comandos (ver o cabeçalho). Cada passo só age se ainda não foi dado.
    def finish!(key, request, regulator)
      case key
      when :missing_diagnosis then request.update_columns(cid10: nil, ciap2: nil) if request.cid10.present? || request.ciap2.present?
      when :performer_without_cnes then own_scheduled!(request, regulator)
      when :external_absence then legacy_absence!(request, regulator)
      end
      request.reload
    end

    # A rede própria agendada como o AppointmentSync faz (a transição com a data) e a unidade
    # sem o CNES que perdeu depois do cadastro.
    def own_scheduled!(request, regulator)
      if request.status == "authorized"
        at = (Time.current + 3.days).change(hour: 9, min: 30)
        check!(CareRegulation::Transition.call(request: request, to: "scheduled", by: regulator, version: request.version, changes: { scheduled_at: at }),
               "agendamento do pedido 15")
      end
      unit = HealthUnit.find_by!(name: POLYCLINIC)
      unit.update!(cnes: nil) if unit.cnes.present?
    end

    # Uma falta gravada como antes da Q24: sem horário, sem fim e sem prestador (INSERT; o andamento nunca muda).
    def legacy_absence!(request, regulator)
      return if request.events.any? { |event| event.status == "missed" }

      RegulationRequestEvent.create!(regulation_request: request, status: "missed", by_user: regulator, created_at: Time.current - 1.hour)
      request.update_columns(misses: 1)
    end

    # --- marcadores do simulado e linhas de envio -----------------------------

    def marked_request(n)
      RegulationCrew.request_of("curitiba", RegulationCrew::REQUESTS.find { |spec| spec[:n] == n })
    end

    # RECUSA-<uuid> e TIMEOUT-<uuid> no identificador do Bundle (a linha nasce aqui, pelo recálculo
    # do envio). Pedido que já teve remessa fica como está.
    def markers!
      { REFUSED_N => "RECUSA", TIMEOUT_N => "TIMEOUT" }.each do |n, marker|
        request = marked_request(n)
        next unless request

        sync = Regulation::RndsSync.recompute!(request, create: true, now: Time.current)
        next if sync.nil? || sync.bundle_identifier.start_with?("#{marker}-") || sync.deliveries.exists?

        sync.update!(bundle_identifier: "#{marker}-#{Digest::UUID.uuid_v5(MARKER_NAMESPACE, "#{marker}:#{request.id}")}")
      end
    end

    def syncs!(requests)
      requests.each_value { |request| Regulation::RndsSync.recompute!(request.reload, create: true, now: Time.current) }
    end

    # motivo => quantos pedidos novos caem nele, pela conferência do envio.
    def blocked_counts(requests)
      settings = RegulationRndsSetting.current
      credential = IntegrationCredential.find_by!(kind: "rnds_regulation")
      BLOCKED.each_with_object({}) do |(reason, key), counts|
        request = requests.fetch(key).reload
        sync = RegulationRndsSync.find_by(regulation_request_id: request.id)
        next unless sync

        facts = Regulation::RiraFacts.for(request: request, settings: settings, credential: credential)
        verdict = Regulation::RndsValidation.call(facts: facts, status: sync.pending_steps.first || Regulation::RndsSync.target(request, settings: settings))
        counts[reason] = 1 if verdict.is_a?(Array) && verdict.last.include?(reason)
      end
    end
  end
end

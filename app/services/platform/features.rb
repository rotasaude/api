# Interruptores de funcionalidade por cidade (ADR 0028; spec 2026-10-05 §3.1;
# contratos §2). O catálogo mora no código; o estado por cidade, em
# city_features (plataforma). `requires` diz o que precisa existir para a
# funcionalidade ser UTILIZÁVEL; ligado e utilizável são coisas diferentes.
module Platform
  module Features
    # environments: nil = disponível em todo ambiente; senão, allowlist (ADR 0032:
    # signature_psc_mock nunca existe em produção).
    Entry = Data.define(:key, :description, :requires, :environments) do
      def initialize(key:, description:, requires:, environments: nil) = super
    end

    SIMULATION_ENVS = %w[development test staging].freeze

    CATALOG = [
      Entry.new(key: "ledi_export",
                description: "Exportação contínua da produção (LEDI APS) para o PEC da cidade",
                requires: %w[record_mode pec_url ibge_code credential:ledi]),
      Entry.new(key: "cadsus_lookup",
                description: "Consulta ao CADSUS na validação presencial",
                requires: %w[credential:cadsus]),
      # ADR 0031: prontuário da APS (módulo 19a), só no modo record.
      Entry.new(key: "clinical_record",
                description: "Prontuário da atenção primária (consulta SOAP, lista de problemas, adendos)",
                requires: %w[record_mode:record]),
      # ADR 0032: assinatura digital ICP-Brasil do prontuário (19b); só com o
      # prontuário utilizável. Desligado: tudo como no 19a; o que já foi
      # assinado continua válido e visível.
      Entry.new(key: "digital_signature",
                description: "Assinatura digital ICP-Brasil do prontuário (consulta e adendo, sem papel)",
                requires: %w[feature:clinical_record]),
      # ADR 0032 (revisão): PSC simulado, só fora de produção. Ligado, a cidade
      # usa apenas o PSC simulado (assinatura sem validade jurídica).
      Entry.new(key: "signature_psc_mock",
                description: "PSC simulado (desenvolvimento) — assinatura sem validade jurídica",
                requires: %w[feature:digital_signature],
                environments: SIMULATION_ENVS),
      # ADR 0033: documentos clínicos da consulta (19c); só com o prontuário
      # utilizável. Desligado: nada novo é emitido; os documentos existentes
      # seguem legíveis e a página de conferência segue respondendo.
      Entry.new(key: "clinical_documents",
                description: "Documentos clínicos (atestado, declaração, receita, requisição) e lista de medicamentos",
                requires: %w[feature:clinical_record]),
      # ADR 0034: receita de controle especial e de antimicrobiano digitais
      # (números do SNCR) e registro da Notificação de papel; só com os
      # documentos clínicos utilizáveis. Desligado: comportamento do 19c.
      Entry.new(key: "controlled_prescriptions",
                description: "Receita de controle especial e de antimicrobiano digitais (SNCR) e registro da Notificação de papel",
                requires: %w[feature:clinical_documents]),
      # ADR 0034: SNCR simulado, só fora de produção. Ligado, os números vêm do
      # SNCR simulado (numeração simulada — sem validade).
      Entry.new(key: "sncr_mock",
                description: "SNCR simulado (desenvolvimento) — numeração simulada, sem validade",
                requires: %w[feature:controlled_prescriptions],
                environments: SIMULATION_ENVS),
      # ADR 0035: linha do tempo do paciente (módulo 20), para o profissional
      # (dashboard) e para o cidadão (wpda). Sem pré-requisito: no modo
      # integrado mostra o que passou pelo Rota Saúde (histórico parcial).
      Entry.new(key: "patient_timeline",
                description: "Linha do tempo do paciente (profissional no dashboard e cidadão no wpda)",
                requires: []),
      # ADR 0035: página para a tela de "sistemas externos" do e-SUS PEC, só no
      # modo integrado. Sem pec_origin e chave HMAC (pec_settings), a página
      # responde pec_disabled.
      Entry.new(key: "pec_external_view",
                description: "Página da linha do tempo para a tela de sistemas externos do e-SUS PEC",
                requires: %w[feature:patient_timeline record_mode:integrated pec_origin pec_hmac_key]),
      # ADR 0036 (Divergência D1): rastreamento do exame (módulo 21a). Vale no
      # modo record e no integrado (guia da recepção e botão no PEC); off não.
      Entry.new(key: "exam_tracking",
                description: "Rastreamento do exame (pedido, regulação, prazos, resultado e ciência)",
                requires: %w[record_mode]),
      # ADR 0036: entrada FHIR do laudo (POST /fhir/DiagnosticReport) por token do prestador.
      Entry.new(key: "exam_fhir_inbound",
                description: "Entrada FHIR do laudo do prestador (DiagnosticReport)",
                requires: %w[feature:exam_tracking]),
      # ADR 0036: "Solicitar exames" dentro da página do PEC (módulo 20).
      Entry.new(key: "exam_pec_bridge",
                description: "Solicitar exames pela tela de sistemas externos do e-SUS PEC",
                requires: %w[feature:exam_tracking feature:pec_external_view]),
      # ADR 0036: laboratório simulado, só fora de produção.
      Entry.new(key: "fake_lab",
                description: "Laboratório simulado (desenvolvimento) — laudos de exemplo, sem validade",
                requires: %w[feature:exam_fhir_inbound],
                environments: SIMULATION_ENVS),
      # ADR 0037: laboratório municipal (módulo 21b) sobre o rastreamento do 21a.
      Entry.new(key: "municipal_lab",
                description: "Laboratório municipal: requisição, amostra, mapa, resultado, liberação e laudo",
                requires: %w[feature:exam_tracking]),
      # ADR 0037: entrada HL7 v2.5.1 (POST /hl7/v2) para o middleware do fornecedor.
      Entry.new(key: "lab_hl7_inbound",
                description: "Entrada HL7 v2.5.1 dos resultados de aparelhos (middleware do laboratório)",
                requires: %w[feature:municipal_lab]),
      # ADR 0037: middleware simulado, só fora de produção.
      Entry.new(key: "fake_middleware",
                description: "Middleware de aparelhos simulado (desenvolvimento) — resultados de exemplo, sem validade",
                requires: %w[feature:lab_hl7_inbound],
                environments: SIMULATION_ENVS),
      # ADR 0038: controle de qualidade do laboratório municipal (módulo 21c).
      Entry.new(key: "lab_quality_control",
                description: "Controle de qualidade do laboratório: CIQ (Westgard, Levey-Jennings, bloqueio da liberação) e CEQ",
                requires: %w[feature:municipal_lab]),
      # ADR 0038: estoque de reagentes e insumos do laboratório municipal.
      Entry.new(key: "lab_inventory",
                description: "Estoque do laboratório: reagentes e insumos com lotes, lote em uso e consumo estimado",
                requires: %w[feature:municipal_lab]),
      # ADR 0039: procedimentos realizados com crítica SIGTAP e faturamento
      # ambulatorial em BPA (módulo 22). Sem pré-requisito de modo (vale nos
      # dois modos de prontuário); o IBGE da cidade vai no BPA-I (M1). Todos os
      # ambientes, sem simulado (M2).
      Entry.new(key: "procedure_billing",
                description: "Faturamento de procedimentos (BPA): procedimentos realizados com crítica SIGTAP e arquivo BPA-I/BPA-C",
                requires: %w[ibge_code]),
      # ADR 0040: linhas de cuidado (módulo 23) — catálogo C2–C7, inscrição
      # confirmada, busca ativa e prévia dos indicadores. Só no modo record
      # (pelo prontuário utilizável).
      Entry.new(key: "care_lines",
                description: "Linhas de cuidado: catálogo C2–C7, inscrição confirmada, busca ativa e prévia dos indicadores",
                requires: %w[feature:clinical_record]),
      # ADR 0042: cadastro territorial (módulo 24a) — microáreas, domicílios,
      # famílias e cadastro individual com as fichas LEDI de cadastro. Só no
      # modo record (pelo prontuário utilizável).
      Entry.new(key: "territory_registry",
                description: "Cadastro territorial: microáreas, domicílios, famílias e cadastro individual com fichas LEDI de cadastro",
                requires: %w[feature:clinical_record])
    ].freeze

    KEYS = CATALOG.map(&:key).freeze
    class UnknownFeature < StandardError; end

    UNREACHABLE = [ "city_unreachable" ].freeze

    module_function

    def available?(entry, env: Rails.env)
      entry.environments.nil? || entry.environments.include?(env.to_s)
    end

    # O catálogo que o ambiente oferece (o maintenance nunca lista o resto).
    def catalog(env: Rails.env) = CATALOG.select { |entry| available?(entry, env: env) }

    # nil também para a entrada indisponível no ambiente.
    def find(key, env: Rails.env)
      entry = CATALOG.find { |candidate| candidate.key == key.to_s }
      entry if entry && available?(entry, env: env)
    end

    def find!(key, env: Rails.env)
      find(key, env: env) || raise(UnknownFeature, "interruptor fora do catálogo: #{key}")
    end

    # Chave do catálogo mas fora deste ambiente (linha órfã não vale nada).
    def unavailable?(key, env: Rails.env)
      CATALOG.any? { |entry| entry.key == key.to_s } && find(key, env: env).nil?
    end

    def enabled?(city, key, env: Rails.env)
      return false if unavailable?(key, env: env)

      find!(key, env: env)
      CityFeature.exists?(city_id: city.id, key: key.to_s, enabled: true)
    end

    # Para a sessão (contratos §1): só a plataforma, sem abrir a cidade.
    def enabled_keys(city, env: Rails.env)
      keys = catalog(env: env).map(&:key)
      CityFeature.where(city_id: city.id, enabled: true, key: keys).order(:key).distinct.pluck(:key)
    end

    # record_mode e pec_url relidos por id: Current.city sai do CityCatalog, com
    # cache de 30 s (desvio 4).
    def settings(city)
      record_mode, pec_url = City.where(id: city.id).pick(:record_mode, :pec_url)
      { record_mode: record_mode, pec_url: pec_url }
    end

    # O que mora no banco da cidade, numa conexão só. nil = não deu para ler
    # (cidade não ativa não é discada; inalcançável vira nil, nunca exceção).
    def city_state(city)
      return nil unless city.servable?

      CityConnection.with(city) do
        pec = PecConfigState.read
        { credentials: IntegrationCredential.pluck(:kind, :last_check_status).to_h,
          ibge_code: CityProfile.current&.ibge_code, pec_origin: pec[:origin], pec_hmac_key: pec[:key] }
      end
    rescue *Maintenance::CityConnectionErrors::CLASSES, ActiveRecord::StatementInvalid
      nil
    end

    def missing(city, key, state: :load, env: Rails.env)
      return [ "unavailable_in_environment" ] if unavailable?(key, env: env)

      entry = find!(key, env: env)
      state = city_state(city) if state == :load
      return UNREACHABLE.dup if state.nil?

      platform = settings(city)
      entry.requires.filter_map { |requirement| missing_for(requirement, platform, state, city: city, env: env) }
    end

    def usable?(city, key, state: :load, env: Rails.env)
      enabled?(city, key, env: env) && missing(city, key, state: state, env: env).empty?
    end

    def summary(city, state: :load, env: Rails.env)
      state = city_state(city) if state == :load
      rows = CityFeature.where(city_id: city.id).index_by(&:key)
      emails = Maintainer.where(id: rows.values.map(&:changed_by_maintainer_id)).pluck(:id, :email_address).to_h

      catalog(env: env).map do |entry|
        row = rows[entry.key]
        lacking = missing(city, entry.key, state: state, env: env)
        enabled = row&.enabled || false
        { key: entry.key, description: entry.description, enabled: enabled, usable: enabled && lacking.empty?,
          missing: lacking, changed_at: row&.changed_at, changed_by: row && emails[row.changed_by_maintainer_id] }
      end
    end

    def set!(city:, key:, enabled:, maintainer:, env: Rails.env)
      find!(key, env: env)
      PlatformRecord.transaction do
        feature = CityFeature.lock.find_or_initialize_by(city_id: city.id, key: key.to_s)
        next feature if feature.persisted? && feature.enabled == enabled

        feature.update!(enabled: enabled, changed_by_maintainer: maintainer, changed_at: Time.current)
        Platform.audit("city.feature_changed", city_id: city.id, key: key.to_s, enabled: enabled,
                                               maintainer_id: maintainer.id)
        feature
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def missing_for(requirement, platform, state, city: nil, env: Rails.env)
      case requirement
      when "record_mode" then "record_mode_off" if platform[:record_mode] == "off"
      when "record_mode:record" then "record_mode_not_record" unless platform[:record_mode] == "record"
      when "record_mode:integrated" then "record_mode_not_integrated" unless platform[:record_mode] == "integrated"
      when "pec_origin" then "pec_origin_missing" unless state[:pec_origin]
      when "pec_hmac_key" then "pec_hmac_key_missing" unless state[:pec_hmac_key]
      when "pec_url" then "pec_url_missing" if platform[:pec_url].blank?
      when "ibge_code" then "ibge_code_missing" if state[:ibge_code].blank?
      when /\Acredential:(\w+)\z/
        kind = Regexp.last_match(1)
        if !state[:credentials].key?(kind) then "credential_missing:#{kind}"
        elsif state[:credentials][kind] == "unauthorized" then "credential_unauthorized:#{kind}"
        end
      # ADR 0032: depender de outra funcionalidade exige a outra LIGADA E
      # UTILIZÁVEL (mesmo state, sem reabrir a cidade).
      when /\Afeature:(\w+)\z/
        dependency = Regexp.last_match(1)
        "#{dependency}_disabled" unless usable?(city, dependency, state: state, env: env)
      else
        raise ArgumentError, "pré-requisito desconhecido no catálogo: #{requirement}"
      end
    end

    # ADR 0035: só se há origem e chave do PEC — nunca o valor da chave.
    module PecConfigState
      module_function

      def read
        return { origin: false, key: false } unless ApplicationRecord.connection.data_source_exists?("pec_settings")

        row = ApplicationRecord.connection.select_one("SELECT pec_origin IS NOT NULL AS origin, hmac_key IS NOT NULL AS key FROM pec_settings LIMIT 1")
        cast = ActiveModel::Type::Boolean.new
        { origin: cast.cast(row&.fetch("origin")) == true, key: cast.cast(row&.fetch("key")) == true }
      end
    end
  end
end

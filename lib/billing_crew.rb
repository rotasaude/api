require "zlib"
require_relative "signature_crew"
require_relative "dev_terminology"

# Semente de dev do módulo 22 (ADR 0039). Dev é fictício mas imita o real:
# recorte SIGTAP de dev com instrumento, CBO e CID; a "UPA 24h Centro" ganha
# o CNES do retrato do CNES (RecordModeCrew); produção da médica e do técnico
# na UPA (faturável BPA-I e BPA-C, um sem CID, um com CBO não permitido), um
# procedimento na UBS (nunca BPA), produção do laboratório municipal
# (biomédica faturável; patologista sem vínculo = pendência de CBO), no dia
# 10 do mês anterior e hoje; configuração do cabeçalho; faturista@ com
# billing_clerk e TOTP. Só Curitiba. Idempotente. Roda depois do LabCrew.
class BillingCrew
  DEV_MAINTAINER = "dev@local".freeze
  UPA = "UPA 24h Centro".freeze
  UBS = "UBS Jardim das Flores".freeze
  LAB = "Laboratório Municipal Central".freeze
  DEV_CNPJ = "11222333000181".freeze
  CLERK = { prefix: "faturista", role: "billing_clerk", secret_env: "DEV_BILLING_CLERK_OTP_SECRET",
            default_secret: "MZQXI5LSNFZXIYJNMRSXMIJBEEQSCIJB" }.freeze
  SETTINGS = { "origin_name" => "SMS Curitiba", "origin_acronym" => "SMS", "destination_body" => "SMS Curitiba - Controle e Avaliacao",
               "management" => "M" }.freeze
  BILLING_CODES = %w[0301060029 0301060096 0301100012 0301060118 0214010015].freeze
  # [prefixo do e-mail de quem fez, estabelecimento, código SIGTAP, CID, quantidade]
  PRODUCTION = [
    [ "profissional", UPA, "0301060029", "I10", 1 ],   # BPA-I faturável
    [ "profissional", UPA, "0301060096", nil, 1 ],     # BPA-I faturável (sem CID na tabela)
    [ "profissional", UPA, "0301060029", nil, 1 ],     # cid_required
    [ "tecnico", UPA, "0301100012", nil, 2 ],          # BPA-C faturável
    [ "tecnico", UPA, "0214010015", nil, 3 ],          # BPA-C faturável
    [ "tecnico", UPA, "0301060096", nil, 1 ],          # cbo_not_allowed
    [ "profissional", UBS, "0301010064", nil, 1 ]      # establishment_is_aps: a UBS nunca gera BPA
  ].freeze
  LAB_PRODUCTION = [ %w[biomedica 0202020380], %w[biomedica 0202010473], %w[biomedica 0202010503], %w[patologista 0202010317] ].freeze
  # D-U1: raça/cor e endereço dos dois primeiros pacientes; o terceiro fica sem (pendência na prova).
  DEMOGRAPHICS = [
    { "race_color" => "03", "address_zip" => "80010000", "address_street" => "Rua XV de Novembro", "address_number" => "1200",
      "address_district" => "Centro" },
    { "race_color" => "05", "ethnicity" => "0001", "address_zip" => "80250210", "address_street" => "Av. Sete de Setembro",
      "address_number" => "SN", "address_complement" => "Bloco B", "address_district" => "Rebouças" }
  ].freeze

  class << self
    # Garante o recorte de dev com os códigos de faturamento na competência do
    # mês e na anterior. Uma SIGTAP real ativa nunca é tocada.
    def seed_platform!
      guard_environment!
      today = Time.zone.today
      competences = [ (today << 1).strftime("%Y%m"), today.strftime("%Y%m") ]
      status = DevTerminology.ensure_sigtap!(codes: BILLING_CODES, competences: competences, label: "semente do faturamento: SIGTAP")
      { competences: competences, status: status }
    end

    def seed_current_city(slug:, password:, admin:)
      guard_environment!
      return { switch: "desligado (só Curitiba liga)", created: [], users: [] } unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      return { switch: "desligado (sem mantenedor #{DEV_MAINTAINER})", created: [], users: [] } unless maintainer

      Platform::Features.set!(city: City.find(Current.city.id), key: Billing::Gate::KEY, enabled: true, maintainer: maintainer)
      upa = upa!(slug)
      clerk = clerk!(slug, password)
      settings!(admin)
      created = production!(slug, upa, clerk) + lab_production!(slug, clerk)
      { switch: "ligado (procedure_billing)", created: created, users: [ clerk.except(:user) ] }
    end

    private

    def guard_environment!
      raise "semente do faturamento: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def upa!(slug)
      # A UBS recebe o mesmo CNES do retrato: a produção dela fica bloqueada só por ser APS.
      [ UBS, UPA ].map do |name|
        unit = HealthUnit.find_by!(name: name)
        unit.update!(cnes: (Zlib.crc32("cnes:#{slug}:#{name}") % 9_000_000 + 1_000_000).to_s) if unit.cnes.nil?
        unit
      end.last
    end

    def clerk!(slug, password)
      user = User.find_or_initialize_by(email_address: "#{CLERK[:prefix]}@#{slug}.demo")
      user.password = password if user.new_record?
      user.save!
      Membership.find_or_create_by!(user: user, role: CLERK[:role], revoked_at: nil) { |m| m.granted_at = Time.current }
      SignatureCrew.ensure_totp(user, secret_env: CLERK[:secret_env], default_secret: CLERK[:default_secret])
      { email: user.email_address, role: CLERK[:role], otpauth_uri: SignatureCrew.otpauth_uri(user), user: user }
    end

    def settings!(admin)
      return if BillingSetting.current

      cnpj = CityProfile.current&.cnpj.to_s
      params = SETTINGS.merge("origin_cnpj" => cnpj.match?(/\A\d{14}\z/) ? cnpj : DEV_CNPJ)
      result = Billing::SaveSettings.call(params: params, by: admin)
      raise "semente do faturamento: configuração recusada (#{result.reason})" if result.failure?
    end

    def dates = [ (Time.zone.today << 1).change(day: 10), Time.zone.today ]

    # Idempotente: só semeia a UPA/UBS se ainda não há procedimento nelas.
    def production!(slug, upa, clerk)
      ubs = HealthUnit.find_by!(name: UBS)
      return [] if PerformedProcedure.where(health_unit_id: [ upa.id, ubs.id ]).exists?

      patients = Patient.order(:created_at, :id).limit(3).to_a
      return [ "sem paciente para a produção da UPA" ] if patients.empty?

      patients.first(2).zip(DEMOGRAPHICS).each do |patient, values|
        next if patient.race_color.present?

        saved = Patients::Demographics.save!(patient, values)
        raise "semente do faturamento: dados do paciente recusados (#{saved.reason})" if saved.failure?
      end
      units = { UPA => upa, UBS => ubs }
      count = 0
      dates.each do |on|
        PRODUCTION.each_with_index do |(prefix, unit_name, code, cid, quantity), index|
          professional = User.find_by!(email_address: "#{prefix}@#{slug}.demo")
          record!(patients[index % patients.size], Billing::Establishment.for_unit(units.fetch(unit_name)), professional, professional, code, cid,
                  quantity, on)
          count += 1
        end
      end
      [ "#{count} procedimentos na UPA e na UBS" ]
    end

    def lab_production!(slug, clerk)
      lab = ExamProvider.find_by!(name: LAB)
      released = LabReport.where(exam_provider_id: lab.id, status: "released", replaces_report_id: nil).sum { |report| Billing::FromLab.call(report) }
      return [ "#{released} itens de laudo do laboratório" ] if PerformedProcedure.where(exam_provider_id: lab.id, source: "manual").exists?

      patients = Patient.order(:created_at, :id).limit(3).to_a
      return [ "sem paciente para a produção do laboratório" ] if patients.empty?

      establishment = Billing::Establishment.for_lab(lab)
      count = 0
      dates.each do |on|
        LAB_PRODUCTION.each_with_index do |(prefix, code), index|
          record!(patients[index % patients.size], establishment, User.find_by!(email_address: "#{prefix}@#{slug}.demo"), clerk[:user], code, nil, 1, on)
          count += 1
        end
      end
      [ "#{count} exames do laboratório", "#{released} itens de laudo do laboratório" ]
    end

    def record!(patient, establishment, professional, recorded_by, code, cid, quantity, on)
      result = Billing::Record.call(patient: patient, establishment: establishment, professional: professional, source: "manual",
                                    recorded_by: recorded_by, params: { "performed_on" => on.iso8601, "sigtap_code" => code,
                                                                        "quantity" => quantity, "cid10" => cid })
      raise "semente do faturamento: procedimento #{code} recusado (#{result.reason})" if result.failure?
    end
  end
end

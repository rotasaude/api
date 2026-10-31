require "zlib"
require "tmpdir"
require_relative "signature_crew"
require_relative "dev_terminology"
require_relative "care_lines_crew"
require_relative "regulation_crew"
require_relative "clinical_record_crew"

# Semente de dev do módulo 28 (ADR 0046), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, `dental_care` LIGADO pelo mantenedor
# de dev; o CEO "CEO Curitiba Centro" (tipo II, todas as especialidades); a eSB
# "eSB Jardim das Flores" (INE 0001234571, tipo 71) na UBS Jardim das Flores,
# associada à eSF da unidade; a dentista (CBO 223208) e a auxiliar (322430) na
# eSB e a endodontista (223212) no CEO, todas com perfil CRO e TOTP fixo; e o
# cenário abaixo, TUDO pelos comandos do app (SaveCeoProfile, AssociateTeam,
# Consultations::Start/SaveDraft/Finalize, CareRegulation::SaveDraft,
# CreateProsthesisOrder e ChangeProsthesisStage).
#
#   o quê                                                      quem         onde
#   registro inicial: 16 e 26 restaurados, 36 extraído         Rafael       UBS
#   plano de 3 itens (2 selantes e 1 restauração), a            Antônio      UBS
#     restauração feita no retorno: plano aberto, 1 feito
#   plano de 3 restaurações, 1 feita no retorno e as 2          Maria        UBS
#     restantes no rascunho de um 2º retorno, que sugere o
#     desfecho "tratamento concluído" (15)
#   consulta odontológica finalizada de gestante inscrita       Ana          UBS
#     no pré-natal (cumpre a prática c3_k)
#   encaminhamento à endodontia (desfecho 3, pedido de          Cristiane    UBS e CEO
#     regulação) e primeira consulta no CEO com endodontia
#     em andamento e plano do CEO
#   40 procedimentos de periodontia e 20 de endodontia (10      Leonardo     CEO
#     de 3 raízes) no mês corrente: periodontia abaixo da
#     meta e endodontia com composição ok
#   registro inicial de boca sem dentes superiores e prótese    Neusa        UBS
#     total maxilar `received` (laboratório terceiro, por nome)
#
# As pessoas são as de semente anterior (CareLinesCrew e RegulationCrew); quem
# não existir (óbito, regulação desligada) tem o cenário pulado, e a saída diz
# por quê. Idempotente: cada passo é achado pelo que já gravou (consulta
# odontológica do paciente, plano, pedido de prótese) e nunca duplicado. Só
# e-mail, papel e otpauth na saída: nunca dado de paciente.
class OralHealthCrew
  UNIT = CareLinesCrew::UNIT
  DEV_MAINTAINER = "dev@local".freeze
  CEO_NAME = "CEO Curitiba Centro".freeze
  TEAM_NAME = "eSB Jardim das Flores".freeze
  TEAM_INE = "0001234571".freeze
  LABORATORY = "Laboratório de Prótese Dental Sorriso Ltda".freeze
  PROBLEM = { "terminology" => "ciap2", "code" => "D82", "action" => "add", "onset_precision" => "month" }.freeze
  CIAP2 = { "D82" => "Doenças dos dentes/gengivas" }.freeze
  CIAP2_VERSION = "dev-saude-bucal".freeze

  STAFF = {
    dentist: { email_prefix: "dentista", name: "Fernanda Cristina Moreira", cbo: "223208", where: :ubs, team: true,
               secret_env: "DEV_DENTIST_OTP_SECRET", default_secret: "DENTISTASEMENTEDEVCWBAORALHEALTH" },
    assistant: { email_prefix: "asb", name: "Juliana Aparecida Santos", cbo: "322430", where: :ubs, team: true,
                 secret_env: "DEV_ORAL_ASSISTANT_OTP_SECRET", default_secret: "AUXILIARSAUDEBUCALDEVCWBORALHLTH" },
    endodontist: { email_prefix: "endodontista", name: "Rodrigo Henrique Tavares", cbo: "223212", where: :ceo, team: false,
                   secret_env: "DEV_ENDODONTIST_OTP_SECRET", default_secret: "ENDODONTISTASEMENTEDEVCWBORALHLT" }
  }.freeze

  # Quem faz cada papel do cenário: [crew de origem, chave].
  PEOPLE = {
    baseline: [ :care_lines, :rafael ], aux_plan: [ :care_lines, :antonio ], plan: [ :care_lines, :maria ],
    pregnant: [ :care_lines, :ana ], referral: [ :regulation, :cristiane ], production: [ :regulation, :leonardo ],
    prosthesis: [ :regulation, :neusa ]
  }.freeze

  SEXTANTS = %w[S1 S2 S3 S4 S5 S6].freeze
  PERIO_CODES = %w[0307030032 0414020154 0414020162 0414020375].freeze
  THREE_ROOTS = [ 16, 17, 18, 26, 27, 28, 36, 37, 46, 47 ].freeze
  TWO_ROOTS = [ 14, 15, 24, 25, 34, 35, 44, 45 ].freeze
  ONE_ROOT = [ 13, 23 ].freeze

  class << self
    # SIGTAP odontológica no recorte de dev (mês e anterior) e o D82 na CIAP-2 de
    # dev. Uma release real ativa nunca é tocada.
    def seed_platform!
      guard_environment!
      today = Time.zone.today
      competences = [ (today << 1).strftime("%Y%m"), today.strftime("%Y%m") ]
      sigtap = DevTerminology.ensure_sigtap!(codes: SigtapSample::ORAL_HEALTH_CODES, competences: competences,
                                             label: "semente da saúde bucal: SIGTAP")
      { sigtap: sigtap, ciap2: ciap2! }
    end

    def seed_current_city(slug:, ddd: nil, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] saúde bucal: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptor não ligado"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end
      unless ClinicalTerms.find("ciap2", "D82")
        raise "semente da saúde bucal: CIAP-2 sem o D82 — rode o db:seed inteiro (OralHealthCrew.seed_platform!) antes"
      end

      city = City.find(Current.city.id)
      Platform::Features.set!(city: city, key: DentalCare::Gate::KEY, enabled: true, maintainer: maintainer)
      DentalAuxiliaryProcedure.ensure_defaults!
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      ubs = HealthUnit.find_by!(name: UNIT)
      ceo = ceo!(admin)
      team = team!(admin, ubs)
      staff = staff!(slug, password, admin, ubs: ubs, ceo: ceo, team: team)

      skipped = scenario!(slug, ubs: ubs, ceo: ceo, staff: staff)

      { switch: DentalCare::Gate.usable?(city) ? "ligado (#{DentalCare::Gate::KEY})" : "ligado, não utilizável",
        units: [ ceo.name, team.name ], consultations: Consultation.where(kind: "dental").count,
        plans: DentalTreatmentPlan.group(:status).count.sort.to_h, prosthesis: DentalProsthesisOrder.group(:stage).count.sort.to_h,
        skipped: skipped,
        users: staff.values.map { |user| { email: user.email_address, role: "health_professional", otpauth_uri: SignatureCrew.otpauth_uri(user) } } }
    end

    # As linhas que o db/seeds.rb imprime: só e-mail, papel e otpauth (nunca dado de paciente).
    def summary_lines(result, password:)
      lines = [ "[seeds] saúde bucal . #{result[:switch]}" \
                "#{"; #{result[:units].join(' e ')}; #{result[:consultations]} consultas; planos #{counts(result[:plans])}; " \
                   "próteses #{counts(result[:prosthesis])}" if result[:units]&.any?}" ]
      lines += Array(result[:skipped]).map { |why| "[seeds]               pulado: #{why}" }
      lines + result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    private

    def guard_environment!
      raise "semente da saúde bucal: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, units: [], consultations: 0, plans: {}, prosthesis: {}, skipped: [], users: [] }

    def counts(hash) = hash.empty? ? "nenhum" : hash.map { |status, count| "#{status} #{count}" }.join(", ")

    def check!(result, what)
      raise "semente da saúde bucal: #{what} recusado (#{result.reason} #{result.details})" if result.failure?

      result
    end

    # --- plataforma -----------------------------------------------------------

    # O D82 na CIAP-2 ativa quando ela é o recorte de dev ("dev-*"): republica os
    # códigos que ela já tem mais o D82. Release real ou ausente nunca é tocada.
    def ciap2!
      return :complete if ClinicalTerms.find("ciap2", "D82")

      active = ClinicalTerms.release("ciap2")
      return :real_ciap2 unless active&.version.to_s.start_with?("dev-")

      rows = Ciap2Code.where(release_id: active.id).pluck(:code, :description).to_h.merge(CIAP2)
      Dir.mktmpdir do |dir|
        Pathname(dir).join("ciap2.csv").write("CODIGO;TITULO\n#{rows.map { |code, title| "#{code};#{title}" }.join("\n")}\n")
        result = Terminology::Import.call(kind: "ciap2", version: CIAP2_VERSION, path: dir, by: "db:seed")
        raise "semente da saúde bucal: CIAP-2 recusada (#{result.reason} #{result.message})" if result.failure?
      end
      :republished
    end

    # --- unidade, equipe e pessoal --------------------------------------------

    def dev_cnes(name) = format("%07d", (Zlib.crc32("health-unit:#{name}") % 9_000_000) + 1_000_000)

    def ceo!(admin)
      unit = HealthUnit.find_by(name: CEO_NAME) || HealthUnit.create!(name: CEO_NAME, kind: "ceo", cnes: dev_cnes(CEO_NAME))
      check!(DentalCare::SaveCeoProfile.call(unit: unit, params: { "ceo_type" => "II", "specialties" => DentalCare::Catalog::CEO_SPECIALTIES }, by: admin),
             "perfil do CEO") unless unit.ceo_profile
      unit
    end

    # A eSB (71) da UBS, associada à eSF/eAP ativa mais antiga dela.
    def team!(admin, ubs)
      team = HealthTeam.find_by(ine: TEAM_INE) || HealthTeam.create!(health_unit: ubs, kind: "71", name: TEAM_NAME, ine: TEAM_INE)
      return team if team.associated_team_id

      population = DentalCare::AssociateTeam.candidates(team).order(:created_at).first
      if population.nil?
        warn "[seeds] saúde bucal: a #{UNIT} não tem eSF/eAP ativa — eSB sem equipe associada"
        return team
      end

      check!(DentalCare::AssociateTeam.call(team: team, params: { "associated_team_id" => population.id }, by: admin), "associação da eSB")
      team.reload
    end

    # { dentist:, assistant:, endodontist: } => User, com perfil, vínculo e (eSB) equipe.
    def staff!(slug, password, admin, ubs:, ceo:, team:)
      STAFF.to_h do |key, spec|
        user = User.find_or_initialize_by(email_address: "#{spec[:email_prefix]}@#{slug}.demo")
        user.password = password
        user.save!
        Membership.find_or_create_by!(user: user, role: "health_professional") { |membership| membership.granted_at = Time.current }
        SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
        user = user.reload
        unit = spec[:where] == :ceo ? ceo : ubs
        profile!(slug, user, spec, admin)
        link!(user, unit, spec, admin)
        member!(user, team, spec) if spec[:team]
        [ key, user.reload ]
      end
    end

    def profile!(slug, user, spec, admin)
      return if user.professional

      seed = "#{slug}:oral-health:#{spec[:email_prefix]}"
      attrs = { professional_name: spec[:name], council: "CRO", council_state: CityProfile.current&.uf.presence || "PR",
                cns: Professionals::Cns.generate(seed), registration_number: (Zlib.crc32(seed) % 90_000 + 10_000).to_s,
                cpf: ScreeningCrew.send(:cpf_for, seed) }
      check!(Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin), "perfil de #{spec[:name]}")
      user.reload
    end

    def link!(user, unit, spec, admin)
      return if user.professional.links.active.exists?(health_unit_id: unit.id, cbo_code: spec[:cbo])

      check!(Professionals::OpenLink.call(professional: user.professional, health_unit_id: unit.id, cbo_code: spec[:cbo], by: admin),
             "vínculo de #{spec[:name]}")
    end

    def member!(user, team, spec)
      return if HealthTeamMember.active.exists?(professional: user.professional, health_team: team)

      HealthTeamMember.create!(professional: user.professional, health_team: team, cbo_code: spec[:cbo], started_on: Time.zone.today - 365)
    end

    # --- cenário --------------------------------------------------------------

    # -> [ motivo do que foi pulado ]
    def scenario!(slug, ubs:, ceo:, staff:)
      skipped = []
      patients = PEOPLE.to_h { |role, (crew, key)| [ role, patient_of(slug, crew, key) ] }
      patients.each { |role, patient| skipped << "#{role}: pessoa da semente anterior ausente" unless patient }
      world = { slug: slug, ubs: ubs, ceo: ceo, dentist: staff.fetch(:dentist), endodontist: staff.fetch(:endodontist) }
      steps = { baseline: :baseline!, aux_plan: :auxiliary_plan!, plan: :plan_to_complete!, pregnant: :pregnant!,
                referral: :referral!, production: :production!, prosthesis: :prosthesis! }
      steps.each { |role, step| send(step, world, patients[role]) if patients[role] }
      skipped
    end

    def patient_of(slug, crew, key)
      cpf = crew == :care_lines ? CareLinesCrew.cpf_for(slug, key) : RegulationCrew.cpf_for(slug, key)
      citizen = Citizen.find_by(cpf: cpf)
      return nil unless citizen

      citizen.patient || Patients::Resolve.call(citizen).payload&.dig(:patient)
    end

    def dental(patient) = Consultation.where(patient_id: patient.id, kind: "dental")

    def citizen_of(patient) = Citizen.find_by!(patient_id: patient.id)

    def restoration(tooth, **extra) = { "sigtap" => "0307010031", "location" => { "kind" => "tooth", "tooth" => tooth } }.merge(extra.transform_keys(&:to_s))

    def sealant(tooth) = { "sigtap" => "0101020066", "location" => { "kind" => "tooth", "tooth" => tooth } }

    # Corpo do rascunho com o bloco <dental_fields> (códigos da FAO). `pregnant` nulo
    # fica de fora (a inscrição no pré-natal grava no Start).
    def body(patient, dental: {}, assessment: "Lesão de cárie com indicação de tratamento restaurador.")
      fields = { "care_type" => 2, "dental_consultation_type" => 1, "oral_health_surveillance" => [ 99 ], "supplies" => [],
                 "dental_outcomes" => [ 16 ], "procedures" => [] }
      fields["pregnant"] = false if patient.sex.to_s == "female"
      { "assessment" => assessment, "evaluated_problems" => [ PROBLEM.merge("onset_on" => Time.zone.today.beginning_of_month.iso8601) ],
        "dental" => fields.merge(dental) }
    end

    # Uma consulta odontológica pelo caminho real: check-in, chamada, início, rascunho
    # e (finalize: true) finalização. O bloco recebe a consulta antes da finalização.
    # -> a consulta (finalizada ou em rascunho).
    def consult!(world, patient, unit:, by:, key:, params:, baseline: false, finalize: true)
      attendance = ClinicalRecordCrew.send(:checked_in!, world[:slug], unit, citizen_of(patient), "bucal-#{key}")
      check!(Attendances::Call.call(attendance: attendance, health_unit_id: unit.id, by: by), "chamada #{key}")
      started = check!(Consultations::Start.call(attendance: attendance.reload, by: by, kind: "dental", baseline: baseline), "consulta #{key}")
      consultation = started.payload.fetch(:consultation)
      check!(Consultations::SaveDraft.call(consultation: consultation, params: params, by: by), "rascunho #{key}")
      yield consultation if block_given?
      return consultation unless finalize

      check!(Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: by),
             "finalização #{key}")
      consultation.reload
    end

    def plan_of(patient, unit) = DentalTreatmentPlan.find_by(patient_id: patient.id, health_unit_id: unit.id)

    # Registro inicial de adulto: 16 e 26 restaurados, 36 extraído.
    def baseline!(world, patient)
      return if dental(patient).exists?

      findings = [ { "tooth" => 16, "situation" => "restored" }, { "tooth" => 26, "situation" => "restored" },
                   { "tooth" => 36, "situation" => "extracted" } ]
      consult!(world, patient, unit: world[:ubs], by: world[:dentist], key: "inicial-#{patient.id[0, 8]}", baseline: true,
                               params: { "dental" => { "findings" => findings } })
    end

    # Plano de 3 itens (2 selantes e 1 restauração); a restauração é feita no retorno.
    # Os selantes ficam para a auxiliar dar baixa na prova.
    def auxiliary_plan!(world, patient)
      return if dental(patient).exists?

      key = "plano-auxiliar-#{patient.id[0, 8]}"
      consult!(world, patient, unit: world[:ubs], by: world[:dentist], key: "#{key}-1",
                               params: body(patient, dental: { "plan_changes" => { "add" => [ restoration(21), sealant(16), sealant(26) ] } }))
      item = plan_of(patient, world[:ubs]).items.find_by!(procedure_code: "0307010031")
      consult!(world, patient, unit: world[:ubs], by: world[:dentist], key: "#{key}-2",
                               params: body(patient, dental: { "dental_consultation_type" => 2,
                                                               "procedures" => [ restoration(21, plan_item_id: item.id) ] }))
    end

    # Plano de 3 restaurações: 1 feita no retorno e as 2 restantes no rascunho de um
    # segundo retorno (sugere o desfecho 15 na prova).
    def plan_to_complete!(world, patient)
      return if dental(patient).exists?

      key = "plano-#{patient.id[0, 8]}"
      consult!(world, patient, unit: world[:ubs], by: world[:dentist], key: "#{key}-1",
                               params: body(patient, dental: { "plan_changes" => { "add" => [ restoration(21), restoration(22), restoration(23) ] } }))
      items = plan_of(patient, world[:ubs]).items.order(:tooth).to_a
      consult!(world, patient, unit: world[:ubs], by: world[:dentist], key: "#{key}-2",
                               params: body(patient, dental: { "dental_consultation_type" => 2,
                                                               "procedures" => [ restoration(items.first.tooth, plan_item_id: items.first.id) ] }))
      consult!(world, patient, unit: world[:ubs], by: world[:dentist], key: "#{key}-3", finalize: false,
                               params: body(patient, dental: { "dental_consultation_type" => 2,
                                                               "procedures" => items.drop(1).map { |i| restoration(i.tooth, plan_item_id: i.id) } }))
    end

    # Gestante inscrita no pré-natal: a consulta odontológica cumpre a prática c3_k.
    def pregnant!(world, patient)
      return if dental(patient).exists?

      consult!(world, patient, unit: world[:ubs], by: world[:dentist], key: "gestante-#{patient.id[0, 8]}",
                               params: body(patient, dental: { "procedures" => [ sealant(16) ] }).tap { |p| p["dental"].delete("pregnant") })
    end

    # Encaminhamento à endodontia (desfecho 3, com o pedido de regulação quando ela está
    # ligada) e a primeira consulta no CEO, com endodontia em andamento e plano do CEO.
    def referral!(world, patient)
      key = "endodontia-#{patient.id[0, 8]}"
      unless attended_at?(patient, world[:ubs])
        consult!(world, patient, unit: world[:ubs], by: world[:dentist], key: "#{key}-1",
                                 params: body(patient, dental: { "dental_outcomes" => [ 3 ] })) do |consultation|
          next unless CareRegulation::Gate.usable?(Current.city)

          attrs = { "type" => "specialty", "target_code" => "223212", "ciap2" => "D82", "suggested_color" => "yellow",
                    "justification" => "Dente com necrose pulpar e indicação de tratamento endodôntico; encaminho ao CEO." }
          check!(CareRegulation::SaveDraft.call(consultation: consultation, attrs: attrs, by: world[:dentist]), "pedido de regulação")
        end
      end
      return if attended_at?(patient, world[:ceo])

      plan = { "add" => [ { "sigtap" => "0307020053", "location" => { "kind" => "tooth", "tooth" => 36 } } ] }
      endo = [ { "tooth" => 36, "canals" => 3, "status" => "in_progress" } ]
      consult!(world, patient, unit: world[:ceo], by: world[:endodontist], key: "#{key}-2",
                               params: body(patient, dental: { "plan_changes" => plan, "endodontics" => endo }))
    end

    def attended_at?(patient, unit) = dental(patient).joins(:attendance).exists?(attendances: { health_unit_id: unit.id })

    # 40 de periodontia (24 + 16, sextante a sextante) e 20 de endodontia (10 de três raízes)
    # no mês corrente, em duas consultas do CEO de um mesmo paciente fictício.
    def production!(world, patient)
      return if attended_at?(patient, world[:ceo])

      key = "producao-#{patient.id[0, 8]}"
      perio = ->(sextants) { PERIO_CODES.flat_map { |code| sextants.map { |sextant| sextant_procedure(code, sextant) } } }
      endo = THREE_ROOTS.map { |t| tooth_procedure("0307020053", t) } + TWO_ROOTS.map { |t| tooth_procedure("0307020045", t) } +
             ONE_ROOT.map { |t| tooth_procedure("0307020061", t) }
      consult!(world, patient, unit: world[:ceo], by: world[:endodontist], key: "#{key}-1",
                               params: body(patient, dental: { "procedures" => perio.(SEXTANTS) }))
      consult!(world, patient, unit: world[:ceo], by: world[:endodontist], key: "#{key}-2",
                               params: body(patient, dental: { "dental_consultation_type" => 2, "procedures" => perio.(SEXTANTS.first(4)) + endo }))
    end

    def sextant_procedure(code, sextant) = { "sigtap" => code, "location" => { "kind" => "sextant", "sextant" => sextant } }

    def tooth_procedure(code, tooth) = { "sigtap" => code, "location" => { "kind" => "tooth", "tooth" => tooth } }

    # Registro inicial de boca sem dentes superiores e prótese total maxilar recebida.
    def prosthesis!(world, patient)
      order = DentalProsthesisOrder.where(patient_id: patient.id).order(:created_at).first
      unless order
        findings = ([ *11..18 ] + [ *21..28 ]).map { |tooth| { "tooth" => tooth, "situation" => "extracted" } }
        baseline = dental(patient).find_by(baseline: true) ||
                   consult!(world, patient, unit: world[:ubs], by: world[:dentist], key: "protese-#{patient.id[0, 8]}", baseline: true,
                                            params: { "dental" => { "findings" => findings } })
        created = DentalCare::CreateProsthesisOrder.call(
          params: { "consultation_id" => baseline.id, "patient_id" => patient.id, "sigtap" => "0701070137",
                    "laboratory" => { "name" => LABORATORY } }, by: world[:dentist]
        )
        order = check!(created, "pedido de prótese").payload.fetch(:order)
      end
      %w[sent received].each do |stage|
        next unless DentalCare::ChangeProsthesisStage::NEXT.fetch(order.reload.stage, []).include?(stage)

        check!(DentalCare::ChangeProsthesisStage.call(order: order, stage: stage, reason: nil, by: world[:dentist]), "etapa #{stage}")
      end
    end
  end
end

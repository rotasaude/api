require_relative "signature_crew"
require_relative "screening_crew"
require_relative "care_lines_crew"
require_relative "territory_registry_crew"

# Semente de dev do módulo 24b (ADR 0052), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, home_visits e collective_activities
# LIGADOS pelo mantenedor de dev; na UBS Jardim das Flores, na equipe do
# TerritoryRegistryCrew, o TACS Juliano César Ramos (tacs@, CBO 322255, sem
# conselho, CNS e CPF válidos), atribuído pela enfermeira da equipe (223505) à
# microárea 02 "Jardim das Flores — sul" — a descoberta do 24a, que não tem
# ACS. Tudo pelos comandos do app (AssignMicroArea, HomeVisits::Record,
# Withdraw, CloseDay, CollectiveActivities::Record, FieldDevices::Register e
# Revoke), com as mesmas validações da tela; nenhuma data por parâmetro: o dia
# vem do corpo (occurred_at da visita, held_on da atividade).
#
#   folha     quando            visita                                             desfecho
#   ontem     09:10             morador: Lorena (criança, peso e altura)           realizada (motivo 8)
#   ontem     09:40             família da Daniela (R. Pedro Gusso, 780)           realizada (29, visita periódica)
#   ontem     10:30             comércio na microárea 02, sem pessoa               realizada (34, ação educativa)
#   ontem     11:15             morador: Cláudio                                   recusada
#   ontem     14:05             morador: Daniela                                   realizada (31) e RETIRADA
#   hoje      agora − 2 h       família da Daniela                                 ausente
#   hoje      agora − 1 h       terreno baldio na microárea 02, sem pessoa         realizada (36, ação mecânica)
#
# A folha de ontem é fechada pela dona (CloseDay, closed_by "user") depois da
# retirada; a ficha 8 nasce no fechamento se a exportação estiver utilizável
# (em dev, como no 24a, a semente não liga ledi_export). A de hoje fica aberta.
# Atividades: um grupo de hipertensos e diabéticos (tipo 5, atendimento em
# grupo) registrado pelo TACS com a enfermeira, com José, Sebastião e Osvaldo
# (CPF, do CareLinesCrew); e uma reunião de equipe (tipo 1) registrada pela
# enfermeira com a ACS e o TACS. Um aparelho de campo do TACS, revogado por
# ele (perdido): só o digest no banco; o token do cadastro é descartado na
# hora (nunca impresso, logado nem gravado).
#
# Idempotente pelo client_uuid (UUID v5 da cidade, do cenário e do DIA da
# visita/atividade): rodar de novo no mesmo dia recebe replayed e não grava
# nada; noutro dia, o "ontem" e o "hoje" são outros e a semente acrescenta os
# do dia (a folha que ficou aberta recebe as visitas de ontem e fecha). A
# retirada, o fechamento, a atribuição e o aparelho conferem o estado antes.
# Roda depois do TerritoryRegistryCrew.
class HomeVisitCrew
  UNIT = CareLinesCrew::UNIT
  TEAM_NAME = CareLinesCrew::TEAM_NAME
  DEV_MAINTAINER = "dev@local".freeze
  FEATURES = [ HomeVisits::Gate::KEY, CollectiveActivities::Gate::KEY ].freeze
  NURSE = "enfermeira".freeze
  ACS = "acs".freeze
  AREA = "02".freeze
  # O domicílio da microárea 02 no TerritoryRegistryCrew (CEP e número).
  HOUSEHOLD = :pedro_gusso
  # Telefone do TACS no bloco do 24a (+55 <ddd> 96666-24NN), longe dos dele (0–8).
  PHONE_INDEX = 20
  TACS = { email_prefix: "tacs", professional_name: "Juliano César Ramos", cbo: "322255", months_in_team: 18,
           secret_env: "DEV_TACS_OTP_SECRET", default_secret: "TACSVISITADOMICILIARSEMENTEQUATR" }.freeze
  DEVICE_NAME = "Celular de campo — Moto G24".freeze
  WITHDRAWAL = "Visita lançada em duplicidade: a orientação já consta na visita à família.".freeze
  # Namespace dos client_uuid da semente (UUID v5 sobre a URL abaixo).
  NAMESPACE = Digest::UUID.uuid_v5(Digest::UUID::URL_NAMESPACE, "https://rotasaude.app/seeds/home_visit_crew")

  # Ontem: hora e minuto fixos. person: chave do TerritoryRegistryCrew.
  YESTERDAY = {
    child: { at: [ 9, 10 ], subject: "resident", person: :lorena, outcome: 1, reasons: [ 8 ],
             measurements: { "weight_kg" => 5.12, "height_cm" => 57.5 } },
    family: { at: [ 9, 40 ], subject: "family_responsible", outcome: 1, reasons: [ 29 ] },
    shop: { at: [ 10, 30 ], subject: "none", property_type: "2", outcome: 1, reasons: [ 34 ] },
    refused: { at: [ 11, 15 ], subject: "resident", person: :claudio, outcome: 2 },
    duplicate: { at: [ 14, 5 ], subject: "resident", person: :daniela, outcome: 1, reasons: [ 31 ], withdraw: true }
  }.freeze
  # Hoje: antes de agora (occurred_at ≤ agora), sem sair do dia.
  TODAY = {
    absent: { ago: 2.hours, subject: "family_responsible", outcome: 3 },
    vacant_lot: { ago: 1.hour, subject: "none", property_type: "3", outcome: 1, reasons: [ 36 ] }
  }.freeze

  # days: o último dia útil a pelo menos N dias de hoje.
  ACTIVITIES = {
    group: { days: 2, by: :tacs, activity_type: 5, shift: 1, place_text: "Salão da Associação de Moradores do Butiatuvinha",
             participants_count: 3, target_audience: [ 12 ], health_topics: [ 4 ], health_practices: [ 20 ], professionals: %i[nurse],
             participants: [
               { person: :jose, altered_evaluation: true, measurements: { "weight_kg" => 86.4, "height_cm" => 171 } },
               { person: :sebastiao, altered_evaluation: false, measurements: { "weight_kg" => 72.8, "height_cm" => 166 } },
               { person: :osvaldo, altered_evaluation: false, measurements: { "weight_kg" => 79.1, "height_cm" => 174 } }
             ] },
    meeting: { days: 4, by: :nurse, activity_type: 1, shift: 2, place_text: "Sala de reuniões da UBS Jardim das Flores",
               participants_count: 5, meeting_topics: [ 3, 4 ], professionals: %i[acs tacs] }
  }.freeze

  class << self
    def seed_current_city(slug:, ddd:, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("desligado (só Curitiba liga)") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] visita domiciliar: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptores não ligados"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      unit = HealthUnit.find_by!(name: UNIT)
      team = HealthTeam.find_by(health_unit: unit, name: TEAM_NAME, active: true) ||
             HealthTeam.where(health_unit: unit, active: true).order(:created_at).first
      area = team && MicroArea.find_by(team: team, code: AREA)
      household = area && household_of(area)
      people = %i[lorena daniela claudio jose sebastiao osvaldo].to_h { |key| [ key, TerritoryRegistryCrew.patient_of(slug, key) ] }
      missing = people.select { |_, patient| patient.nil? }.keys
      unless team && area && household && missing.empty?
        raise "semente da visita domiciliar: falta o cadastro territorial (#{missing.join(', ').presence || "microárea #{AREA}"}) " \
              "— rode o TerritoryRegistryCrew (db:seed) antes"
      end

      city = City.find(Current.city.id)
      FEATURES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
      CityCatalog.reset_cache!

      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      staff = { nurse: User.find_by!(email_address: "#{NURSE}@#{slug}.demo"), acs: User.find_by!(email_address: "#{ACS}@#{slug}.demo") }
      staff[:tacs] = tacs!(slug, ddd, password, admin, unit, team)
      assign!(area, staff[:tacs], staff[:nurse])

      family = Family.active_families.find_by!(household_id: household.id, responsible_patient_id: people.fetch(:daniela).id)
      place = { team: team, area: area, household: household, family: family }
      yesterday = yesterday!(slug, staff[:tacs], place, people)
      today = today!(slug, staff[:tacs], place)
      activities = ACTIVITIES.to_h { |key, data| [ key, activity!(slug, key, data, staff, team, people) ] }
      device!(staff[:tacs])

      summary(city, team, area, staff[:tacs], yesterday, today, activities)
    end

    # Só e-mail, papel e otpauth (nunca CPF, CNS, nome de paciente ou token).
    def summary_lines(result, password:)
      head = "[seeds] visita domiciliar #{result[:switch]}"
      return [ head ] unless result[:team]

      [ "#{head}; equipe #{result[:team]}; microárea #{result[:micro_area]}",
        "[seeds]               folha de ontem #{result[:yesterday].map { |k, v| "#{k} #{v}" }.join(', ')}",
        "[seeds]               folha de hoje #{result[:today].map { |k, v| "#{k} #{v}" }.join(', ')}",
        "[seeds]               atividades #{result[:activities].map { |k, v| "tipo #{k}: #{v} participantes" }.join('; ')}",
        "[seeds]               aparelhos do TACS: #{result[:devices]}" ] +
        result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    # client_uuid estável pela cidade, cenário e dia.
    def client_uuid(slug, kind, key, day) = Digest::UUID.uuid_v5(NAMESPACE, "#{slug}:#{kind}:#{key}:#{day.iso8601}")

    private

    def guard_environment!
      raise "semente da visita domiciliar: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, team: nil, micro_area: nil, yesterday: nil, today: nil, activities: nil, devices: nil, users: [] }

    # O domicílio da R. Pedro Gusso (achado como no TerritoryRegistryCrew: CEP e número).
    def household_of(area)
      address = TerritoryRegistryCrew::HOUSEHOLDS.fetch(HOUSEHOLD)[:address]
      Household.where(micro_area: area).detect do |household|
        household.latest_version.address.values_at("zip", "number") == address.values_at("zip", "number")
      end
    end

    # O TACS como a ACS do 24a: usuário, papel, TOTP, perfil de campo (sem
    # conselho), vínculo 322255 na UBS e na equipe.
    def tacs!(slug, ddd, password, admin, unit, team)
      user = User.find_or_initialize_by(email_address: "#{TACS[:email_prefix]}@#{slug}.demo")
      user.password = password
      user.save!
      Membership.find_or_create_by!(user: user, role: "health_professional") { |m| m.granted_at = Time.current }
      SignatureCrew.ensure_totp(user, secret_env: TACS[:secret_env], default_secret: TACS[:default_secret])
      professional = user.professional || tacs_profile!(slug, ddd, user, admin)
      unless professional.links.active.exists?(health_unit: unit, cbo_code: TACS[:cbo])
        opened = Professionals::OpenLink.call(professional: professional, health_unit_id: unit.id, cbo_code: TACS[:cbo], by: admin)
        raise "semente da visita domiciliar: vínculo do TACS recusado (#{opened.reason})" if opened.failure?
      end
      unless HealthTeamMember.active.exists?(professional: professional, health_team: team)
        HealthTeamMember.create!(professional: professional, health_team: team, cbo_code: TACS[:cbo],
                                 started_on: Time.zone.today << TACS[:months_in_team])
      end
      user.reload
    end

    def tacs_profile!(slug, ddd, user, admin)
      seed = "#{slug}:#{TACS[:email_prefix]}"
      attrs = { professional_name: TACS[:professional_name], cns: Professionals::Cns.generate(seed),
                cpf: ScreeningCrew.send(:cpf_for, seed), phone: TerritoryRegistryCrew.phone_for(ddd, PHONE_INDEX) }
      result = Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin)
      raise "semente da visita domiciliar: perfil do TACS recusado (#{result.reason} #{result.details})" if result.failure?

      result.payload[:professional]
    end

    # A enfermeira da equipe atribui a microárea 02 ao TACS (uma vez).
    def assign!(area, tacs, nurse)
      return if MicroAreaFieldAssignment.active.exists?(micro_area: area, professional: tacs.professional)
      raise "semente da visita domiciliar: a enfermeira não atribui na equipe" unless HomeVisits::Access.assigner?(nurse, area.team)

      assigned = HomeVisits::AssignMicroArea.call(micro_area: area, professional_id: tacs.professional.id, by: nurse)
      raise "semente da visita domiciliar: atribuição recusada (#{assigned.reason})" if assigned.failure?
    end

    # Grava as visitas de ontem, retira a duplicada e fecha a(s) folha(s) delas.
    # -> as folhas de ontem com visita da semente.
    def yesterday!(slug, tacs, place, people)
      day = Time.zone.today - 1
      visits = YESTERDAY.to_h do |key, data|
        time = day.in_time_zone.change(hour: data[:at][0], min: data[:at][1])
        [ key, record!(slug, key, data, time, tacs, place, people) ]
      end
      YESTERDAY.each { |key, data| withdraw!(visits.fetch(key), tacs) if data[:withdraw] }
      HomeVisitDay.where(id: visits.values.map(&:home_visit_day_id).uniq).order(:sequence).each { |sheet| close!(sheet, tacs) }
      HomeVisitDay.where(id: visits.values.map(&:home_visit_day_id).uniq).order(:sequence).to_a
    end

    # -> a folha aberta de hoje com as visitas da semente.
    def today!(slug, tacs, place)
      now = Time.current
      visits = TODAY.map do |key, data|
        record!(slug, key, data, [ now - data[:ago], now.beginning_of_day ].max, tacs, place, {})
      end
      HomeVisitDay.find(visits.last.home_visit_day_id)
    end

    def record!(slug, key, data, time, tacs, place, people)
      params = { "client_uuid" => client_uuid(slug, "home_visit", key, time.to_date), "team_id" => place[:team].id,
                 "occurred_at" => time.iso8601, "subject" => data[:subject], "outcome" => data[:outcome] }
      if data[:property_type]
        params.merge!("micro_area_id" => place[:area].id, "property_type" => data[:property_type])
      else
        params["household_id"] = place[:household].id
      end
      params["family_id"] = place[:family].id if data[:subject] == "family_responsible"
      params["patient_id"] = people.fetch(data[:person]).id if data[:person]
      params["reasons"] = data[:reasons] if data[:reasons]
      params["measurements"] = data[:measurements] if data[:measurements]

      recorded = HomeVisits::Record.call(params: params, by: tacs)
      raise "semente da visita domiciliar: visita #{key} recusada (#{recorded.reason} #{recorded.details})" if recorded.failure?

      recorded.payload[:visit]
    end

    def withdraw!(visit, tacs)
      visit.reload
      return if visit.withdrawn?

      unless visit.home_visit_day.open?
        warn "[seeds] visita domiciliar: a visita a retirar está numa folha já fechada — mantida"
        return
      end
      withdrawn = HomeVisits::Withdraw.call(visit, by: tacs, expected_state: "recorded", reason: WITHDRAWAL)
      raise "semente da visita domiciliar: retirada recusada (#{withdrawn.reason})" if withdrawn.failure?
    end

    def close!(sheet, tacs)
      return unless sheet.open?

      closed = HomeVisits::CloseDay.call(sheet, by: tacs, closed_by: "user")
      raise "semente da visita domiciliar: fechamento recusado (#{closed.reason})" if closed.failure?
    end

    def activity!(slug, key, data, staff, team, people)
      held_on = weekday_before(data[:days])
      params = { "client_uuid" => client_uuid(slug, "collective_activity", key, held_on), "team_id" => team.id,
                 "held_on" => held_on.iso8601, "shift" => data[:shift], "activity_type" => data[:activity_type],
                 "place_text" => data[:place_text], "participants_count" => data[:participants_count],
                 "professionals" => data[:professionals].map { |who| { "professional_id" => staff.fetch(who).professional.id } } }
      %i[meeting_topics target_audience health_topics health_practices].each { |field| params[field.to_s] = data[field] if data[field] }
      if data[:participants]
        params["participants"] = data[:participants].map do |item|
          { "patient_id" => people.fetch(item[:person]).id, "altered_evaluation" => item[:altered_evaluation],
            "measurements" => item[:measurements] }
        end
      end

      recorded = CollectiveActivities::Record.call(params: params, by: staff.fetch(data[:by]))
      raise "semente da visita domiciliar: atividade #{key} recusada (#{recorded.reason} #{recorded.details})" if recorded.failure?

      recorded.payload[:activity]
    end

    # O último dia útil (segunda a sexta) a pelo menos `days` dias de hoje.
    def weekday_before(days)
      day = Time.zone.today - days
      day -= 1 while day.saturday? || day.sunday?
      day
    end

    # Um aparelho do TACS, revogado por ele. O token do cadastro não sai daqui:
    # só o aparelho do payload é lido.
    def device!(tacs)
      device = FieldDevice.where(user_id: tacs.id).order(:created_at).first
      unless device
        registered = FieldDevices::Register.call(user: tacs, name: DEVICE_NAME)
        raise "semente da visita domiciliar: aparelho recusado (#{registered.reason})" if registered.failure?

        device = registered.payload[:device]
      end
      return if device.revoked?

      revoked = FieldDevices::Revoke.call(device, by: tacs, reason: "user")
      raise "semente da visita domiciliar: revogação recusada (#{revoked.reason})" if revoked.failure?
    end

    def switch_label(city)
      missing = FEATURES.reject { |key| Platform::Features.usable?(city, key) }
      return "ligado (#{FEATURES.join(' e ')})" if missing.empty?

      "ligado, não utilizável (falta: #{missing.flat_map { |key| Platform::Features.missing(city, key) }.uniq.join(', ')})"
    end

    def ficha_label(sheet)
      return "gerada" if LediOutboxEntry.exists?(source_type: Ledi::HomeVisitDayFicha::SOURCE_TYPE, source_id: sheet.id)

      failure = LediGenerationFailure.find_by(source_type: Ledi::HomeVisitDayFicha::SOURCE_TYPE, source_id: sheet.id)
      return "não gerada (#{failure.reason_codes.join(', ')})" if failure

      "não gerada (ledi_export desligado ou não utilizável)"
    end

    def summary(city, team, area, tacs, yesterday, today, activities)
      { switch: switch_label(city), team: team.name, micro_area: "#{area.code} #{area.name} (TACS #{tacs.professional.professional_name})",
        yesterday: { state: yesterday.map(&:state).uniq.join("/"), visits: yesterday.sum { |s| s.home_visits.valid.count },
                     withdrawn: yesterday.sum { |s| s.home_visits.where.not(withdrawn_at: nil).count },
                     ficha: yesterday.map { |s| ficha_label(s) }.uniq.join("/") },
        today: { state: today.state, visits: today.home_visits.valid.count },
        activities: activities.values.to_h { |activity| [ activity.activity_type, activity.participants.count ] },
        devices: FieldDevice.where(user_id: tacs.id).map(&:state).tally.map { |state, n| "#{n} #{state}" }.join(", "),
        users: [ { email: tacs.email_address, role: "health_professional (TACS #{TACS[:cbo]})", otpauth_uri: SignatureCrew.otpauth_uri(tacs) } ] }
    end
  end
end

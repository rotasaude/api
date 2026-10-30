require "active_support/testing/time_helpers"
require "zlib"
require_relative "signature_crew"
require_relative "digital_signature_crew"
require_relative "care_lines_crew"
require_relative "regulation_crew"
require_relative "controlled_prescriptions_crew"

# Semente de dev do módulo 27a (ADR 0045), para a prova no navegador. Dev é
# fictício mas imita o real: em Curitiba, `pharmacy` LIGADO pelo mantenedor de
# dev e os parâmetros padrão (o dump não leva a linha); o almoxarifado central e
# a farmácia da UBS Jardim das Flores; a equipe (a farmacêutica com CBO 223405
# real, perfil CRF e vínculo com a UBS; a auxiliar e os dois almoxarifes com
# perfil profissional sem conselho e SEM vínculo, pois nenhum CBO deles consta da
# tabela de saúde; todos com TOTP fixo; o usuário não tem campo de nome, o nome
# vem do perfil profissional); e o cenário abaixo,
# TUDO pelos comandos do app (SaveLocation, LinkStaff, RecordEntry, SendTransfer,
# ReceiveTransfer, RequestAdjustment, SaveMinimums, ClinicalDocuments::Issue e
# Cancel, RecordExternalPrescription, Dispense), com as datas passadas vindas de
# travel_to em volta do comando, sempre até um segundo antes de agora.
#
#   o quê                                                       onde     quando
#   abertura: LOSARTANA 50 mg (2 lotes, um vence em 60 dias),
#     METFORMINA, SINVASTATINA, AMOXICILINA, FLUOXETINA,
#     DIAZEPAM e SALBUTAMOL (aerosol, frasco)                   central  há 40 dias
#   transferência recebida inteira (7 itens)                    → UBS    há 30 dias
#   NF 000123456, LOSARTANA 30 × 20 caixas                      central  há 20 dias
#   transferência recebida com diferença (2 caixas avariadas)   → UBS    há 10 dias
#   transferência em trânsito (METFORMINA)                      → UBS    hoje
#   ajuste pendente de 20% (contagem de SINVASTATINA)           central  hoje
#   mínimo de METFORMINA acima do saldo (e os demais abaixo)    UBS      —
#
# Receitas (todas pelo Issue, nas consultas que a RegulationCrew já gravou: a
# consulta é a de cada pessoa, no dia dela):
#
#   pessoa      receita                                           situação
#   José        LOSARTANA contínua (consulta de há 50 dias)       dispensada há 26 dias (próxima liberada)
#   Sebastião   LOSARTANA contínua (consulta de há 45 dias)       dispensada há 10 dias (too_early)
#   Márcia      AMOXICILINA, emitida há 40 dias                   prescription_expired
#   Paulo       AMOXICILINA, emitida há 3 dias                    válida, antimicrobiano (retenção)
#   Iolanda     item em TEXTO LIVRE (sinvastatina)                válida; só a farmacêutica mapeia
#   Roberto     FLUOXETINA 20 mg (C1, controle especial)          não dispensada; só a farmacêutica, com retenção
#   Valdir      LOSARTANA, emitida há 25 dias e CANCELADA         prescription_cancelled
#   (sem CPF)   receita EXTERNA de DIAZEPAM B1, notificação       na UBS, não dispensada
#               PR-2026-000777, paciente digitado (como no 24a)
#
# A forma farmacêutica: o recorte do CATMAT de dev só traz forma em três itens
# (paracetamol, salbutamol, miconazol); os seis do cenário nascem sem ela e a
# unidade de dispensação cairia em "unidade". `seed_platform!` completa SÓ o
# que está em branco (a forma que o CATMAT traz nunca é tocada), com a forma
# real de cada apresentação; uma nova release do catálogo refaz a leitura e a
# semente completa de novo. Itens com forma: comprimido, cápsula e frasco.
#
# A FLUOXETINA exige controlled_prescriptions utilizável e o contato de
# prescritor da médica (ControlledPrescriptionsCrew); sem isso a receita é
# pulada e a saída diz por quê. A receita controlada sai em papel (a médica de
# dev não tem certificado ligado), então sem número SNCR: com certificado
# ligado antes da semente, sairia digital com número simulado. O mesmo vale
# para o antimicrobiano.
#
# Idempotente: local, lote, nota, transferência (pelo conjunto de lotes),
# ajuste, receita e dispensação são achados e retomados, nunca duplicados; o
# que a prova mexer (transferência recebida, ajuste decidido) fica como está.
# Só e-mail, papel e otpauth na saída: nunca dado de paciente nem código de
# receita.
class PharmacyCrew
  UNIT = CareLinesCrew::UNIT
  DEV_MAINTAINER = "dev@local".freeze
  CENTRAL = "Central de Abastecimento Farmacêutico de Curitiba".freeze
  PHARMACY = "Farmácia da UBS Jardim das Flores".freeze

  # code: CATMAT do recorte de dev; form: forma a completar quando o CATMAT não a traz.
  ITEMS = {
    losartana: { code: 268_856, form: "comprimido" },
    metformina: { code: 267_690, form: "comprimido" },
    sinvastatina: { code: 267_747, form: "comprimido" },
    amoxicilina: { code: 271_089, form: "cápsula" },
    fluoxetina: { code: 273_009, form: "cápsula" },
    diazepam: { code: 267_197, form: "comprimido" },
    salbutamol: { code: 294_887, form: nil } # "aerosol oral" no CATMAT: frasco
  }.freeze

  STAFF = {
    pharmacist: { email_prefix: "farmacia", name: "Ana Paula Wisniewski", role: "pharmacist", where: %i[unit], cbo: "223405", council: "CRF",
                  secret_env: "DEV_PHARMACIST_OTP_SECRET", default_secret: "FARMACEUTICASEMENTEDEVCWBAPHARMA" },
    assistant: { email_prefix: "farmacia.auxiliar", name: "Marcos Vinícius Andrade", role: "pharmacy_assistant", where: %i[unit], cbo: nil, council: nil,
                 secret_env: "DEV_PHARMACY_ASSISTANT_OTP_SECRET", default_secret: "AUXILIARFARMACIASEMENTEDEVCWBAPH" },
    keeper: { email_prefix: "almoxarifado", name: "Luiz Fernando Kuster", role: "stock_keeper", where: %i[central unit], cbo: nil, council: nil,
              secret_env: "DEV_STOCK_KEEPER_OTP_SECRET", default_secret: "ALMOXARIFESEMENTEDEVCWBAPHARMACY" },
    keeper2: { email_prefix: "almoxarifado.2", name: "Cristiane Bortolini", role: "stock_keeper", where: %i[central], cbo: nil, council: nil,
               secret_env: "DEV_STOCK_KEEPER_2_OTP_SECRET", default_secret: "ALMOXARIFEDOISSEMENTEDEVCWBAPHAR" }
  }.freeze

  # Inventário de abertura do central (há 40 dias). days: validade a partir de hoje.
  OPENING = [
    { item: :losartana, lot: "LS2411-A", days: 60, quantity: "400" },
    { item: :losartana, lot: "LS2705-B", days: 540, quantity: "1200" },
    { item: :metformina, lot: "MF2702-A", days: 400, quantity: "1500" },
    { item: :sinvastatina, lot: "SV2705-A", days: 420, quantity: "800" },
    { item: :amoxicilina, lot: "AM2701-A", days: 300, quantity: "600" },
    { item: :fluoxetina, lot: "FL2704-A", days: 500, quantity: "300" },
    { item: :diazepam, lot: "DZ2706-A", days: 480, quantity: "200" },
    { item: :salbutamol, lot: "SB2703-A", days: 360, quantity: "150" }
  ].freeze
  # Nota fiscal (há 20 dias): 30 comprimidos por caixa × 20 caixas.
  INVOICE = { number: "000123456", supplier: "Distribuidora de Medicamentos Paraná Ltda.", item: :losartana, lot: "LS2706-C", days: 600,
              units_per_package: 30, packages: 20 }.freeze
  # Transferências central → UBS: o que sai (lote, quantidade) e quando; `received` é o que a UBS conta.
  WHOLE = { days_ago: 30, lines: [ [ "LS2705-B", "300" ], [ "MF2702-A", "400" ], [ "SV2705-A", "200" ], [ "AM2701-A", "120" ],
                                  [ "FL2704-A", "60" ], [ "DZ2706-A", "40" ], [ "SB2703-A", "60" ] ] }.freeze
  DIFFERENT = { days_ago: 10, lines: [ [ "LS2706-C", "300" ] ], received: "240", reason: "Duas caixas avariadas no transporte" }.freeze
  IN_TRANSIT = { days_ago: 0, lines: [ [ "MF2702-A", "300" ] ] }.freeze
  ADJUSTMENT = { lot: "SV2705-A", counted: "480", reason: "Contagem física no almoxarifado central: 480 comprimidos contra 600 no sistema." }.freeze
  # Mínimos da UBS: só a metformina fica acima do saldo (400 contra 600).
  MINIMUMS = { metformina: "600", losartana: "200", sinvastatina: "100", amoxicilina: "50", fluoxetina: "20", diazepam: "10" }.freeze

  # As receitas, pelo pedido da regulação cuja consulta as recebe (n é o do
  # RegulationCrew::REQUESTS: 6 José, 10 Sebastião, 2 Márcia, 4 Paulo, 3 Iolanda,
  # 1 Roberto, 7 Valdir). `dispense`: a retirada da semente (dias atrás, hora,
  # quem, lote e quantidade). `retention_of: :controlled` só com controlled_prescriptions.
  ADDRESS = ControlledPrescriptionsCrew::ADDRESS
  PRESCRIPTIONS = [
    { n: 6, label: "receita de uso contínuo do pedido 6 da regulação", item: :losartana, quantity: 60, unit: "comprimido", continuous: true,
      dosage: "1 comprimido de 12 em 12 horas, uso contínuo.", dispense: { days_ago: 26, hour: 10, by: :assistant, lot: "LS2705-B", quantity: "60" } },
    { n: 10, label: "receita de uso contínuo do pedido 10 da regulação", item: :losartana, quantity: 60, unit: "comprimido", continuous: true,
      dosage: "1 comprimido de 12 em 12 horas, uso contínuo.", dispense: { days_ago: 10, hour: 16, by: :pharmacist, lot: "LS2705-B", quantity: "60" } },
    { n: 2, label: "receita de AMOXICILINA (vencida)", item: :amoxicilina, quantity: 21, unit: "cápsula", duration: 7,
      dosage: "1 cápsula a cada 8 horas, por 7 dias." },
    { n: 4, label: "receita de AMOXICILINA (válida)", item: :amoxicilina, quantity: 21, unit: "cápsula", duration: 7,
      dosage: "1 cápsula a cada 8 horas, por 7 dias." },
    { n: 3, label: "receita com item em texto livre", free_text: "Sinvastatina 20 mg, comprimido", quantity: 30, unit: "comprimido",
      dosage: "1 comprimido à noite, por 30 dias." },
    { n: 7, label: "receita cancelada", item: :losartana, quantity: 30, unit: "comprimido", cancel: true,
      dosage: "1 comprimido pela manhã, por 30 dias." },
    { n: 1, label: "receita de FLUOXETINA (controle especial)", item: :fluoxetina, quantity: 30, unit: "cápsula", duration: 30, special: true,
      dosage: "1 cápsula pela manhã, por 30 dias." }
  ].freeze
  CANCEL_REASON = "Receita trocada: o paciente voltou antes de retirar.".freeze
  EXTERNAL = {
    patient: { "full_name" => "Aparecido Domingos Tavares", "birth_date" => "1957-04-12", "sex" => "male",
               "mother_name" => "Benta Domingos Tavares", "no_cpf_reason" => "5" },
    prescriber: { "name" => "Henrique Salvador Moreira", "council" => "CRM", "council_state" => "PR", "council_number" => "28471" },
    notification_number: "PR-2026-000777", issued_days_ago: 5, quantity: "30", quantity_unit: "comprimido",
    dosage_instructions: "1 comprimido à noite, por 30 dias."
  }.freeze

  class << self
    include ActiveSupport::Testing::TimeHelpers

    # A forma farmacêutica dos itens do cenário (só o que está em branco).
    def seed_platform!
      guard_environment!
      filled = ITEMS.values.filter_map do |spec|
        next unless spec[:form]

        item = MedicationCatalogItem.find_by(catmat_code: spec[:code])
        next unless item && item.dosage_form.blank?

        item.update_columns(dosage_form: spec[:form])
        spec[:code]
      end
      { forms: filled.size }
    end

    def seed_current_city(slug:, ddd: nil, password: ENV.fetch(SignatureCrew::PASSWORD_ENV, "dev-password"))
      guard_environment!
      return off("fora") unless slug == "curitiba"

      maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
      unless maintainer
        warn "[seeds] farmácia: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptor não ligado"
        return off("desligado (sem mantenedor #{DEV_MAINTAINER})")
      end

      city = City.find(Current.city.id)
      Platform::Features.set!(city: city, key: Pharmacy::Gate::KEY, enabled: true, maintainer: maintainer)
      PharmacySetting.ensure_defaults!
      admin = User.find_by!(email_address: "admin@#{slug}.demo")
      unit = HealthUnit.find_by!(name: UNIT)
      central = location!(admin, kind: "central", name: CENTRAL)
      pharmacy = location!(admin, kind: "unit", name: PHARMACY, unit: unit)
      staff = staff!(slug, password, admin, unit, central: central, unit_location: pharmacy)

      clock = Time.current
      catalog = catalog!
      stock!(clock, catalog, central: central, pharmacy: pharmacy, staff: staff)
      skipped = prescriptions!(slug, clock, catalog, pharmacy: pharmacy, staff: staff)

      { switch: Pharmacy::Gate.usable?(city) ? "ligado (#{Pharmacy::Gate::KEY})" : "ligado, não utilizável",
        locations: [ central.name, pharmacy.name ], lots: StockLot.count, transfers: StockTransfer.group(:status).count.sort.to_h,
        adjustments: StockAdjustment.group(:status).count.sort.to_h, dispensations: Dispensation.count, skipped: skipped,
        users: staff.values.map { |user| { email: user.email_address, role: role_of(user), otpauth_uri: SignatureCrew.otpauth_uri(user) } } }
    end

    # As linhas que o db/seeds.rb imprime: só e-mail, papel e otpauth (nunca dado de paciente).
    def summary_lines(result, password:)
      lines = [ "[seeds] farmácia .... #{result[:switch]}" \
                "#{"; locais #{result[:locations].join(' e ')}; #{result[:lots]} lotes; transferências #{counts(result[:transfers])}; " \
                   "ajustes #{counts(result[:adjustments])}; #{result[:dispensations]} dispensações" if result[:locations]&.any?}" ]
      lines += Array(result[:skipped]).map { |why| "[seeds]               pulado: #{why}" }
      lines + result[:users].map { |u| "[seeds]               #{u[:email]} (#{u[:role]}) / #{password} → #{u[:otpauth_uri]}" }
    end

    private

    def guard_environment!
      raise "semente da farmácia: ambiente implantado; a semente é só de dev" if Rota.deployed?
    end

    def off(switch) = { switch: switch, locations: [], lots: 0, transfers: {}, adjustments: {}, dispensations: 0, skipped: [], users: [] }

    def counts(hash) = hash.empty? ? "nenhum" : hash.map { |status, count| "#{status} #{count}" }.join(", ")

    def at(time, clock, &) = travel_to([ time, clock - 1.second ].min, &)

    def day_at(clock, days_ago, hour) = (clock.to_date - days_ago).in_time_zone.change(hour: hour)

    def check!(result, what)
      raise "semente da farmácia: #{what} recusado (#{result.reason} #{result.details.slice(:path, :problems)})" if result.failure?

      result
    end

    # --- locais e equipe ------------------------------------------------------

    def location!(admin, kind:, name:, unit: nil)
      existing = kind == "central" ? StockLocation.find_by(kind: "central") : StockLocation.find_by(health_unit_id: unit.id)
      return existing if existing

      saved = Pharmacy::SaveLocation.call(attrs: { "kind" => kind, "name" => name, "health_unit_id" => unit&.id }.compact, by: admin)
      check!(saved, "local #{name}").payload.fetch(:location)
    end

    # { pharmacist:, assistant:, keeper:, keeper2: } => User, já vinculados.
    def staff!(slug, password, admin, unit, central:, unit_location:)
      places = { central: central, unit: unit_location }
      STAFF.to_h do |key, spec|
        user = User.find_or_initialize_by(email_address: "#{spec[:email_prefix]}@#{slug}.demo")
        user.password = password
        user.save!
        roles = key == :pharmacist ? [ spec[:role], "health_professional" ] : [ spec[:role] ]
        roles.each { |role| Membership.find_or_create_by!(user: user, role: role) { |membership| membership.granted_at = Time.current } }
        SignatureCrew.ensure_totp(user, secret_env: spec[:secret_env], default_secret: spec[:default_secret])
        user = user.reload
        profile!(slug, user, spec, admin, unit)
        spec[:where].each { |place| link!(places.fetch(place), user, spec[:role], admin) }
        [ key, user ]
      end
    end

    # Perfil profissional (é dele que vem o nome que a API mostra) e, só quando a
    # função tem CBO aceito pela tabela de saúde, o vínculo com a UBS (a
    # farmacêutica, 223405). Só ela é health_professional e passa pelo
    # Professionals::Create; a auxiliar e os almoxarifes não têm esse papel (ele
    # daria autoridade clínica), então o perfil deles é gravado direto, sem
    # conselho (conselho, UF e registro: todos ou nenhum) e sem vínculo.
    def profile!(slug, user, spec, admin, unit)
      unless user.professional
        seed = "#{slug}:pharmacy:#{spec[:email_prefix]}"
        attrs = { professional_name: spec[:name], cns: Professionals::Cns.generate(seed) }
        if spec[:council]
          attrs.merge!(council: spec[:council], council_state: CityProfile.current&.uf.presence || "PR",
                       registration_number: (Zlib.crc32(seed) % 90_000 + 10_000).to_s)
        end
        if user.has_role?("health_professional")
          check!(Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin), "perfil de #{spec[:name]}")
        else
          Professional.create!(attrs.merge(user: user))
        end
        user.reload
      end
      user.professional.update!(cpf: DigitalSignatureCrew.free_cpf_for(slug, user.professional)) if user.professional.cpf.blank?
      return if spec[:cbo].nil? || user.professional.links.active.exists?(health_unit_id: unit.id, cbo_code: spec[:cbo])

      check!(Professionals::OpenLink.call(professional: user.professional, health_unit_id: unit.id, cbo_code: spec[:cbo], by: admin),
             "vínculo de #{spec[:name]}")
    end

    def link!(location, user, role, admin)
      linked = Pharmacy::LinkStaff.add(location: location, user_id: user.id, role: role, by: admin)
      check!(linked, "vínculo de #{user.email_address} ao local") unless linked.ok? || linked.reason == :already_linked
    end

    def role_of(user) = STAFF.values.find { |spec| user.email_address.start_with?("#{spec[:email_prefix]}@") }.fetch(:role)

    # --- estoque --------------------------------------------------------------

    # { chave => MedicationCatalogItem }
    def catalog!
      ITEMS.to_h do |key, spec|
        item = MedicationCatalogItem.find_by(catmat_code: spec[:code])
        raise "semente da farmácia: item #{spec[:code]} fora do catálogo — rode o db:seed inteiro (medicamentos) antes" unless item

        [ key, item ]
      end
    end

    def stock!(clock, catalog, central:, pharmacy:, staff:)
      keeper = staff.fetch(:keeper)
      today = Time.zone.today
      opening!(clock, catalog, central, keeper, today)
      transfer!(clock, central, pharmacy, keeper, WHOLE, :whole)
      invoice!(clock, catalog, central, keeper, today)
      transfer!(clock, central, pharmacy, keeper, DIFFERENT, :difference)
      transfer!(clock, central, pharmacy, keeper, IN_TRANSIT, nil)
      adjustment!(central, keeper)
      minimums!(catalog, pharmacy, keeper)
    end

    def lot(number) = StockLot.find_by!(lot_number: number)

    def entry_row(catalog, spec, today, **more)
      { "catalog_item_id" => catalog.fetch(spec[:item]).id, "lot_number" => spec[:lot], "expires_on" => (today + spec[:days]).iso8601 }.merge(more)
    end

    # Abertura (um item por abertura): só os itens sem abertura no central.
    def opening!(clock, catalog, central, keeper, today)
      pending = OPENING.reject { |spec| StockOpening.exists?(stock_location_id: central.id, catalog_item_id: catalog.fetch(spec[:item]).id) }
      return if pending.empty?

      items = pending.map { |spec| entry_row(catalog, spec, today, "quantity" => spec[:quantity]) }
      by_id = catalog.values.index_by(&:id)
      result = at(day_at(clock, 40, 9), clock) do
        Pharmacy::RecordEntry.call(location: central, kind: "opening", document: nil, items: items, by: keeper, catalog: by_id)
      end
      check!(result, "inventário de abertura")
    end

    def invoice!(clock, catalog, central, keeper, today)
      return if StockEntry.exists?(stock_location_id: central.id, kind: "invoice", document_number: INVOICE[:number])

      row = entry_row(catalog, INVOICE, today, "package" => { "units_per_package" => INVOICE[:units_per_package], "packages" => INVOICE[:packages] })
      result = at(day_at(clock, 20, 11), clock) do
        Pharmacy::RecordEntry.call(location: central, kind: "invoice", document: { "number" => INVOICE[:number], "supplier" => INVOICE[:supplier] },
                                   items: [ row ], by: keeper, catalog: catalog.values.index_by(&:id))
      end
      check!(result, "nota fiscal #{INVOICE[:number]}")
    end

    # A transferência é achada pelo CONJUNTO de lotes (central → UBS): o que a
    # prova recebeu fica como está; uma enviada e ainda não recebida é retomada.
    # `received`: :whole (tudo o que saiu), :difference (spec[:received] no
    # lote, com o motivo) ou nil (fica em trânsito).
    def transfer!(clock, central, pharmacy, keeper, spec, received)
      lots = spec[:lines].map { |number, _quantity| lot(number) }
      transfer = StockTransfer.where(from_location_id: central.id, to_location_id: pharmacy.id).includes(:items)
                              .find { |candidate| candidate.items.map(&:stock_lot_id).sort == lots.map(&:id).sort }
      unless transfer
        items = spec[:lines].map { |number, quantity| { "lot_id" => lot(number).id, "quantity" => quantity } }
        sent = at(day_at(clock, spec[:days_ago], 9), clock) { Pharmacy::SendTransfer.call(from: central, to: pharmacy, items: items, by: keeper) }
        transfer = check!(sent, "envio da transferência").payload.fetch(:transfer)
      end
      return transfer unless received && transfer.status == "sent"

      items = transfer.items.map do |item|
        counted = received == :difference ? spec[:received] : item.quantity_sent.to_s("F")
        { "lot_id" => item.stock_lot_id, "quantity_received" => counted }.merge(received == :difference ? { "reason" => spec[:reason] } : {})
      end
      done = at(day_at(clock, spec[:days_ago], 15), clock) { Pharmacy::ReceiveTransfer.call(transfer: transfer, items: items, by: keeper) }
      check!(done, "recebimento da transferência")
    end

    # Contagem de SINVASTATINA no central, 20% abaixo do saldo: espera a
    # segunda almoxarife. Achado por (local, lote, tipo): decidido na prova, não volta.
    def adjustment!(central, keeper)
      lot = lot(ADJUSTMENT[:lot])
      return if StockAdjustment.exists?(stock_location_id: central.id, stock_lot_id: lot.id, kind: "adjustment")

      result = Pharmacy::RequestAdjustment.call(location: central, lot: lot, kind: "adjustment", counted_quantity: ADJUSTMENT[:counted], quantity: nil,
                                                reason: ADJUSTMENT[:reason], by: keeper, settings: Pharmacy::Settings.current)
      check!(result, "ajuste de contagem")
    end

    # Só quando a UBS ainda não tem mínimo nenhum (a lista é substituída por inteiro).
    def minimums!(catalog, pharmacy, keeper)
      return if StockMinimum.exists?(stock_location_id: pharmacy.id)

      rows = MINIMUMS.map { |key, minimum| { "catalog_item_id" => catalog.fetch(key).id, "minimum" => minimum } }
      check!(Pharmacy::SaveMinimums.call(location: pharmacy, rows: rows, by: keeper), "mínimos da UBS")
    end

    # --- receitas e dispensações ---------------------------------------------

    # -> [ motivo, ... ] das receitas que não saíram (a saída diz por quê).
    def prescriptions!(slug, clock, catalog, pharmacy:, staff:)
      doctor = User.find_by!(email_address: "profissional@#{slug}.demo")
      controlled = controlled_unavailable(doctor)
      skipped = PRESCRIPTIONS.filter_map do |spec|
        why = (controlled if spec[:special]) || prescription!(slug, clock, catalog, doctor, spec, pharmacy: pharmacy, staff: staff)
        next unless why

        warn "[seeds] farmácia: #{spec[:label]} pulada (#{why})"
        "#{spec[:label]}: #{why}"
      end
      external!(clock, catalog, pharmacy, staff)
      skipped
    end

    # Por que a receita de controle especial não sai (nil quando sai).
    def controlled_unavailable(doctor)
      return "controlled_prescriptions desligado" unless ControlledPrescriptions::Gate.usable?(City.find(Current.city.id))
      return "sem o contato de prescritor da médica" unless doctor.professional&.prescriber_contact

      nil
    end

    # Emite (ou acha), cancela e dispensa conforme a tabela. -> nil quando a
    # receita existe, ou o motivo de ter sido pulada.
    def prescription!(slug, clock, catalog, doctor, spec, pharmacy:, staff:)
      request_spec = RegulationCrew::REQUESTS.find { |candidate| candidate[:n] == spec[:n] }
      request = RegulationCrew.request_of(slug, request_spec)
      consultation = request&.consultation
      return "sem a consulta (rode o RegulationCrew)" unless consultation
      return "óbito registrado" if request_spec[:care_lines] && CareLinesCrew.deceased?(Citizen.find_by(patient_id: consultation.patient_id))

      document = existing_prescription(consultation.patient_id, spec, catalog) || issue!(clock, doctor, consultation, request, spec, catalog)
      cancel!(clock, doctor, document) if spec[:cancel] && !document.cancelled?
      dispense!(clock, document, spec, catalog, pharmacy, staff) if spec[:dispense] && !Dispensation.exists?(clinical_document_id: document.id)
      nil
    end

    # A receita da semente do paciente (pelo item do catálogo, ou o texto livre).
    def existing_prescription(patient_id, spec, catalog)
      scope = ClinicalDocument.where(kind: "prescription", patient_id: patient_id).joins(:prescription_items)
                              .where(prescription_items: { medication_catalog_item_id: spec[:item] && catalog.fetch(spec[:item]).id })
      scope = scope.where(prescription_items: { continuous: true }) if spec[:continuous]
      scope.order(:issued_at, :id).first
    end

    def content_for(spec, catalog)
      line = { "quantity" => spec[:quantity], "quantity_unit" => spec[:unit], "route" => "oral", "dosage_instructions" => spec[:dosage] }
      line["duration_days"] = spec[:duration] if spec[:duration]
      line["continuous"] = true if spec[:continuous]
      line.merge!(spec[:free_text] ? { "free_text" => spec[:free_text] } : { "catalog_item" => { "id" => catalog.fetch(spec[:item]).id } })
      content = { "items" => [ line ] }
      content["patient_identification"] = { "address" => ADDRESS } if spec[:special]
      content
    end

    # Pela consulta que a regulação gravou, dez minutos depois de ela virar pedido.
    def issue!(clock, doctor, consultation, request, spec, catalog)
      issued = at(request.requested_at + 10.minutes, clock) do
        ClinicalDocuments::Issue.call(kind: "prescription", content: content_for(spec, catalog), by: doctor, consultation: consultation.reload)
      end
      check!(issued, spec[:label]).payload.fetch(:document)
    end

    def cancel!(clock, doctor, document)
      cancelled = at(document.issued_at + 2.hours, clock) do
        ClinicalDocuments::Cancel.call(document_id: document.id, by: doctor, reason: CANCEL_REASON)
      end
      check!(cancelled, "cancelamento da receita")
    end

    # A retirada da semente na farmácia da UBS, na data e pelo papel da tabela.
    def dispense!(clock, document, spec, catalog, pharmacy, staff)
      plan = spec.fetch(:dispense)
      settings = Pharmacy::Settings.current
      prescription = Pharmacy::Prescription.find(kind: "digital", id: document.id, settings: settings)
      items = [ { "prescription_item_id" => prescription.items.first.id, "lot_id" => lot(plan[:lot]).id, "quantity" => plan[:quantity] } ]
      by_id = Pharmacy::Json.catalog_for(prescription.items.filter_map(&:catalog_item_id))
      result = at(day_at(clock, plan[:days_ago], plan[:hour]), clock) do
        Pharmacy::Dispense.call(location: pharmacy, prescription: prescription, items: items, retention: nil, by: staff.fetch(plan[:by]),
                                role: STAFF.fetch(plan[:by]).fetch(:role), catalog: by_id, settings: settings)
      end
      check!(result, "dispensação da #{spec[:label]}")
    end

    # Receita externa de DIAZEPAM B1 na UBS, para paciente digitado sem CPF (como
    # no 24a, com CNS gerado). Achada pelo prescritor (o conselho é público).
    def external!(clock, catalog, pharmacy, staff)
      writer = EXTERNAL[:prescriber]
      return if ExternalPrescription.exists?(stock_location_id: pharmacy.id, council: writer["council"], council_state: writer["council_state"],
                                             council_number: writer["council_number"])

      item = catalog.fetch(:diazepam)
      patient = EXTERNAL[:patient].merge("cns" => Professionals::Cns.generate("curitiba:pharmacy:external"))
      line = { "catalog_item_id" => item.id, "quantity" => EXTERNAL[:quantity], "quantity_unit" => EXTERNAL[:quantity_unit],
               "dosage_instructions" => EXTERNAL[:dosage_instructions] }
      today = Time.zone.today
      result = at(day_at(clock, EXTERNAL[:issued_days_ago], 10), clock) do
        Pharmacy::RecordExternalPrescription.call(location: pharmacy, patient_id: nil, new_patient: patient, prescriber: writer,
                                                  issued_on: (today - EXTERNAL[:issued_days_ago]).iso8601,
                                                  notification_number: EXTERNAL[:notification_number], items: [ line ], by: staff.fetch(:pharmacist),
                                                  role: "pharmacist", catalog: { item.id => item }, today: today)
      end
      check!(result, "receita externa")
    end
  end
end

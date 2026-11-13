require "rails_helper"
require Rails.root.join("lib/signature_crew").to_s
require Rails.root.join("lib/professional_crew").to_s
require Rails.root.join("lib/triage_catalog_crew").to_s
require Rails.root.join("lib/screening_crew").to_s
require Rails.root.join("lib/clinical_record_crew").to_s
require Rails.root.join("lib/care_lines_crew").to_s
require Rails.root.join("lib/regulation_crew").to_s
require Rails.root.join("lib/clinical_documents_crew").to_s
require Rails.root.join("lib/controlled_prescriptions_crew").to_s
require Rails.root.join("lib/pharmacy_crew").to_s
require Rails.root.join("lib/urgency_crew").to_s

# Semente de dev do módulo 32a (ADR 0050) no banco de teste (nunca no de dev),
# com o elenco na ordem do db/seeds.rb até o CareLinesCrew (a UPA, a UBS, a
# equipe da ESF e o José com a consulta da médica). Cada exemplo prova o que a
# prova no navegador precisa achar sem preparo manual. Idempotente; a saída
# nunca leva CPF, CNS, nome nem descrição de paciente.
RSpec.describe UrgencyCrew, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { clinical_city! }
  let(:unit) { HealthUnit.find_by!(name: UrgencyCrew::UNIT) }

  # A cadeia anterior do db/seeds.rb, uma vez por arquivo (api#159).
  seed_once do
    city = clinical_city!
    create_default_protocol!
    admin = staff_with("admin@curitiba.demo", "municipal_admin")
    Maintainer.create!(email_address: "dev@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    SignatureCrew.seed_current_city(slug: "curitiba", password: "dev-password")
    ProfessionalCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    Territory::Seed.call(path: Territory::Seed.path_for("curitiba"))
    TriageCatalogCrew.seed_current_city(slug: "curitiba", ddd: "41")
    ScreeningCrew.seed_platform!
    ScreeningCrew.seed_current_city(slug: "curitiba", ddd: "41")
    ClinicalRecordCrew.seed_platform!
    ClinicalRecordCrew.seed_current_city(slug: "curitiba", ddd: "41")
    CareLinesCrew.seed_platform!
    RegulationCrew.seed_platform!
    ClinicalDocumentsCrew.seed_platform!
    PharmacyCrew.seed_platform!
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    CareLinesCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    RegulationCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    ClinicalDocumentsCrew.seed_current_city(slug: "curitiba")
    ControlledPrescriptionsCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
    PharmacyCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
  end

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def user(prefix) = User.find_by!(email_address: "#{prefix}@curitiba.dev")

  def counts
    [ UrgencyEncounter.count, UrgencyClassification.count, UrgencyOutcome.count, Attendance.count, Patient.count, CallLocation.count,
      WaitingRoomDisplay.count, User.count, Membership.count, Professional.count, ProfessionalLink.count, CityFeature.count,
      ProtocolDefinition.count, Consultation.count, UrgencyBed.count, UrgencyBedStay.count, UrgencyPrescription.count,
      UrgencyPrescriptionItem.count, UrgencyAdministration.count, StockLocation.count, StockLocationStaff.count, StockEntry.count,
      StockMovement.count, UrgencyStockShortfall.count ]
  end

  it "fora de Curitiba só o rascunho do protocolo: sem interruptor, equipe, local, TV nem paciente; idempotente" do
    staff_with("autor@maringa.demo", "protocol_author")
    result = described_class.seed_current_city(slug: "maringa", ddd: "44", password: "dev-password")
    again = described_class.seed_current_city(slug: "maringa", ddd: "44", password: "dev-password")
    draft = ProtocolDefinition.find_by!(name: "classificacao-urgencia")

    aggregate_failures do
      expect(result[:switch]).to eq("fora")
      expect(again[:protocol]).to eq(result[:protocol])
      expect([ draft.version, draft.status ]).to eq([ 1, "draft" ])
      expect(ProtocolDefinition.urgency_protocols.where(status: "active")).to be_empty
      expect(ProtocolDefinition.where(name: "classificacao-urgencia").count).to eq(1)
      expect([ UrgencyEncounter.count, CallLocation.count, WaitingRoomDisplay.count, CityFeature.where(key: %w[urgency_care waiting_room_display]).count ])
        .to eq([ 0, 0, 0, 0 ])
      expect(User.where("email_address LIKE '%@maringa.dev'")).to be_empty
    end
  end

  # A semente sob teste roda uma vez para os exemplos abaixo (api#159): cada
  # um parte do estado que ela deixou, e `seeded` é o que ela devolveu. Quem
  # chama `seed` de novo prova a segunda rodada (idempotência).
  describe "depois da semente de Curitiba" do
    seed_once { @seeded = seed }

    def seeded = @seeded

    it "liga os dois interruptores e deixa a UPA com prefixo de senha, TV com tempos e os quatro locais" do
      result = seeded

      aggregate_failures do
        expect(result[:switch]).to eq("ligado (urgency_care e waiting_room_display)")
        expect(Urgency::Gate.usable?(city)).to be(true)
        expect(WaitingRoom::Gate.usable?(city)).to be(true)
        expect([ unit.ticket_prefix, unit.show_wait_times ]).to eq([ "U", true ])
        expect(CallLocation.where(health_unit_id: unit.id).pluck(:name))
          .to match_array([ "Classificação de risco", "Consultório 1", "Consultório 2", "Sala de medicação" ])
        display = WaitingRoomDisplay.find_by!(health_unit_id: unit.id)
        expect([ display.name, display.show_wait_times, display.active ]).to eq([ "TV da recepção", true, true ])
      end
    end

    it "a equipe tem papel, TOTP fixo, CBO real no vínculo da UPA e só a enfermagem 2235 classifica" do
      aggregate_failures do
        expect(user("upa").memberships.pluck(:role)).to eq([ "citizen_verifier" ])
        expect(user("upa").professional).to be_nil
        %w[upaenf upamed].each { |prefix| expect(user(prefix).memberships.pluck(:role)).to eq([ "health_professional" ]) }
        expect(%w[upa upaenf upamed].map { |prefix| user(prefix).mfa_enrolled? }).to all(be(true))
        expect(user("upaenf").professional.links.active.where(health_unit_id: unit.id).pluck(:cbo_code)).to eq([ "223505" ])
        expect(user("upamed").professional.links.active.where(health_unit_id: unit.id).pluck(:cbo_code)).to eq([ "225125" ])
        expect(Urgency::Access.classifier(user("upaenf"), unit.id)).to be_ok
        expect(Urgency::Access.classifier(user("upamed"), unit.id)).to be_failure
        expect(user("upaenf").professional.council).to eq("COREN")
        expect(user("upamed").professional.council).to eq("CRM")
      end
    end

    it "o protocolo ativo é o classificacao-urgencia v1 da semente, assinado pelo ciclo" do
      active = ProtocolDefinition.urgency_protocols.where(status: "active")
      aggregate_failures do
        expect(active.pluck(:name, :version)).to eq([ [ "classificacao-urgencia", 1 ] ])
        expect(Urgency::ActiveProtocol.current).to eq(active.first)
        expect(Urgency::Levels.for(active.first).values).to eq([ 0, 10, 60, 120, 240 ])
        expect(active.first.definition["classification_rules"].size).to eq(11)
      end
    end

    it "a fila tem 4 classificados e 1 aguardando; o laranja estourou pela regra da 1ª classificação (Q18)" do
      groups = Urgency::Queue.groups(unit)
      colors = groups[:by_color].map { |item| item[:color] }
      orange = groups[:by_color].find { |item| item[:color] == "orange" }
      encounter = UrgencyEncounter.find(orange[:encounter_id])

      aggregate_failures do
        expect(groups[:by_color].size).to eq(4)
        expect(groups[:awaiting_classification].size).to eq(1)
        expect(groups[:in_care].size).to eq(2) # os dois da observação (32b)
        expect(colors).to eq(%w[orange yellow green green]) # a ordem da fila: cor, depois a chegada
        expect(groups[:by_color].map { |item| item[:overdue] }).to eq([ true, false, false, false ])
        expect(orange[:waited_minutes]).to be >= 24
        expect(((Time.current - encounter.first_classified_at) / 60).floor).to be > encounter.current_classification.max_wait_minutes
        expect(encounter.current_classification.max_wait_minutes).to eq(10)
        expect(groups[:by_color].first[:ticket]).to match(/\AU-\d{3,4}\z/)
      end
    end

    it "classifica pelo protocolo: a cor aceita é a sugerida, e o azul reclassificado para verde guarda a justificativa" do
      patient = Patient.find_by!(cpf: described_class.cpf_for("curitiba", :juliana))
      encounter = UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: patient.id })
      first, second = encounter.classifications.order(:position).to_a
      roberto = UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: Patient.find_by!(cpf: described_class.cpf_for("curitiba", :roberto)).id })

      aggregate_failures do
        expect([ first.color, second.color, encounter.current_classification.color ]).to eq(%w[blue green green])
        expect(first.suggested_color).to be_nil
        expect(first.justification.length).to be >= 10
        expect(second.justification.length).to be >= 10
        expect(roberto.current_classification).to have_attributes(color: "orange", suggested_color: "orange", pain_scale: 8)
        expect(UrgencyClassification.pluck(:pain_scale)).to all(be_an(Integer))
        expect(UrgencyClassification.all.map { |c| c.classified_by_user.email_address }.uniq).to eq([ "upaenf@curitiba.dev" ])
      end
    end

    it "o não identificado aguarda classificação como provisório" do
      provisional = Patient.where(unidentified: true).first
      encounter = UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: provisional.id })
      aggregate_failures do
        expect(provisional.unidentified_description).to eq(described_class::UNIDENTIFIED)
        expect(encounter.state).to eq("waiting_classification")
      end
    end

    it "o encontro de ontem do José fecha com alta para a UBS e aparece na contrarreferência dele e no histórico" do
      jose = Patient.find_by!(cpf: CareLinesCrew.cpf_for("curitiba", :jose))
      encounter = UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: jose.id, health_unit_id: unit.id })
      ubs = HealthUnit.find_by!(name: CareLinesCrew::UNIT)
      consultation = Consultation.find_by!(attendance_id: encounter.attendance_id)

      aggregate_failures do
        expect(encounter).to be_closed
        expect(encounter.attendance.checked_in_at).to be < 23.hours.ago
        expect(consultation).to have_attributes(kind: "urgency", status: "finalized")
        expect(consultation.author_user.email_address).to eq("upamed@curitiba.dev")
        expect(encounter.outcome).to have_attributes(kind: "discharged_to_primary_care", return_days: 7)
        expect(encounter.outcome.recorded_by_user.email_address).to eq("upamed@curitiba.dev")
        referrals = Urgency::CounterReferrals.for(unit: ubs)
        expect(referrals.map { |item| item[:encounter_id] }).to eq([ encounter.id ])
        expect(referrals.first).to include(return_days: 7, upa: { name: UrgencyCrew::UNIT })
      end
    end

    it "o código da TV vale 10 min, é novo a cada semente e pareia" do
      first = seeded
      second = seed
      paired = WaitingRoom::Pair.call(code: second[:tv_code])

      aggregate_failures do
        expect(first[:tv_code]).to match(/\A\d{6}\z/)
        expect(paired).to be_ok
        expect(WaitingRoomDisplay.count).to eq(1)
      end
    end

    it "rodar duas vezes não duplica encontros, classificações, locais, TVs nem equipe" do
      before_counts = counts
      seed

      aggregate_failures do
        expect(counts).to eq(before_counts)
        expect(UrgencyEncounter.count).to eq(8)
        expect(UrgencyClassification.count).to eq(8) # 1 + 1 + 1 + 2 + 1 (ontem) + 2 (observação)
        expect(UrgencyOutcome.count).to eq(1)
        expect(Urgency::Queue.groups(unit)[:by_color].size).to eq(4)
      end
    end

    it "o resumo leva só e-mail, papel, otpauth e o código da TV: nenhum nome, CPF, CNS nem descrição de paciente" do
      result = seeded
      text = described_class.summary_lines(result, password: "dev-password").join("\n")
      patient_data = Patient.pluck(:full_name, :cpf, :cns, :unidentified_description).flatten.compact.reject(&:blank?)
      names = (described_class::PEOPLE.values + described_class::WARD.values).map { |person| person.fetch(:name) } + [ described_class::UNIDENTIFIED ]

      aggregate_failures do
        expect(text).to match(/TV: código \d{6}, vale 10 min/)
        expect(text).to include("upa@curitiba.dev (citizen_verifier)", "upaenf@curitiba.dev (health_professional)", "upamed@curitiba.dev (health_professional)")
        expect(text).to include("otpauth://")
        expect(text).to include("leitos: 4", "faltas abertas: 1")
        (names + patient_data).each { |value| expect(text).not_to include(value) }
        expect(text.upcase).not_to include("LOSARTANA", "DIAZEPAM", "SALBUTAMOL", "AMOXICILINA", "PARACETAMOL")
      end
    end

    it "uma semente dois dias depois não duplica nada nem levanta" do
      before_counts = counts
      travel_to(2.days.from_now) { expect { seed }.not_to raise_error }

      expect(counts).to eq(before_counts)
    end

    describe "a observação (32b)" do
      let(:board) { Urgency::Observation.board(unit) }
      let(:pharmacist) { User.find_by!(email_address: "farmacia@curitiba.demo") }
      let(:upa_location) { StockLocation.find_by!(health_unit_id: unit.id, kind: "unit") }

      def drug(key) = MedicationCatalogItem.find_by!(catmat_code: described_class::STOCK_ITEMS.fetch(key).fetch(:code))

      def ward_encounter(key)
        UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: Patient.find_by!(cpf: described_class.cpf_for("curitiba", key)).id })
      end

      it "liga a baixa de estoque, cria os quatro leitos e o mapa tem 2 ocupados (near_limit e over_limit) e 2 livres" do
        result = seeded

        aggregate_failures do
          expect(Urgency::StockGate.usable?(city)).to be(true)
          expect(result[:beds]).to eq(4)
          expect(board[:beds].map { |bed| bed[:label] }).to eq([ "OBS 01", "OBS 02", "OBS 03", "OBS 04" ])
          expect(board[:beds].map { |bed| bed[:stay]&.fetch(:alert) }).to eq([ "near_limit", "over_limit", nil, nil ])
          expect(board[:waiting_bed]).to be_empty
          expect(UrgencyBedStay.count).to eq(3) # Benedito trocou do OBS 03 para o OBS 02
          expect(ward_encounter(:benedito).bed_stays.map { |stay| stay.urgency_bed.label }).to eq([ "OBS 03", "OBS 02" ])
          expect(ward_encounter(:benedito).bed_stays.first.end_kind).to eq("bed_change")
        end
      end

      it "o técnico 322205 do ProfessionalCrew tem login e vínculo ativo na UPA, e é ele quem checa" do
        technician = User.find_by!(email_address: "tecnico@curitiba.demo")

        aggregate_failures do
          expect(technician.mfa_enrolled?).to be(true)
          expect(technician.professional.links.active.where(health_unit_id: unit.id).pluck(:cbo_code)).to eq([ "322205" ])
          expect(UrgencyAdministration.all.map { |a| a.recorded_by_user.email_address }.uniq).to eq([ "tecnico@curitiba.demo" ])
          expect(UrgencyPrescription.all.map { |p| p.prescribed_by_user.email_address }.uniq).to eq([ "upamed@curitiba.dev" ])
        end
      end

      it "a Maria tem a prescrição v1 com o controlado, duas doses baixadas do estoque e o paracetamol recusado com motivo" do
        prescription = ward_encounter(:maria).prescriptions.sole
        items = prescription.items.index_by(&:catalog_item_id)
        diazepam = items.fetch(drug(:diazepam).id)
        checks = UrgencyAdministration.where(urgency_encounter_id: ward_encounter(:maria).id)

        aggregate_failures do
          expect([ prescription.version, prescription.status ]).to eq([ 1, "active" ])
          expect(items.size).to eq(3)
          expect(diazepam.controlled_list).to be_present
          expect(items.fetch(drug(:paracetamol).id)).to have_attributes(frequency_kind: "if_needed", max_per_day: 4)
          expect(checks.where(status: "administered").count).to eq(2)
          expect(checks.where(status: "administered").map { |a| [ a.stock_lot&.lot_number.present?, a.stock_movement&.kind ] }.uniq).to eq([ [ true, "administration" ] ])
          refused = checks.find_by!(status: "refused")
          expect(refused.reason.length).to be >= 10
          expect(UrgencyStockShortfall.joins(:urgency_administration).where(urgency_administrations: { urgency_encounter_id: ward_encounter(:maria).id })).to be_empty
        end
      end

      it "o Benedito tem a prescrição v2 (a v1 substituída) e a checagem do salbutamol gera a falta insufficient_balance" do
        v1, v2 = ward_encounter(:benedito).prescriptions.to_a
        shortfall = UrgencyStockShortfall.sole

        aggregate_failures do
          expect([ v1.status, v2.status, v2.version, v2.supersedes_id ]).to eq([ "superseded", "active", 2, v1.id ])
          expect(v2.items.map(&:catalog_item_id)).to match_array([ drug(:amoxicilina).id, drug(:salbutamol).id ])
          expect(StockMovement.where(stock_location_id: upa_location.id, stock_lot_id: StockLot.where(catalog_item_id: drug(:salbutamol).id).select(:id))).to be_empty
          expect([ shortfall.cause, shortfall.stock_location_id, shortfall.catalog_item_id ]).to eq([ "insufficient_balance", upa_location.id, drug(:salbutamol).id ])
          expect(shortfall.urgency_administration).to have_attributes(status: "administered", stock_lot_id: nil)
        end
      end

      it "a farmacêutica da UPA vê 1 falta aberta, e o José segue sem observação nem consulta de urgência aberta" do
        jose = Patient.find_by!(cpf: CareLinesCrew.cpf_for("curitiba", :jose))
        jose_encounter = UrgencyEncounter.joins(:attendance).find_by!(attendances: { patient_id: jose.id, health_unit_id: unit.id })

        aggregate_failures do
          expect(Pharmacy::LinkStaff.add(location: upa_location, user_id: pharmacist.id, role: "pharmacist", by: User.find_by!(email_address: "admin@curitiba.demo")).reason)
            .to eq(:already_linked)
          expect(Pharmacy::ReconcileUrgencyShortfall.allowed?(user: pharmacist, location: upa_location)).to be(true)
          expect(UrgencyStockShortfall.open_shortfalls.where(stock_location_id: upa_location.id).pluck(:cause)).to eq([ "insufficient_balance" ])
          expect(Pharmacy::Alerts.call(location: upa_location, today: Time.zone.today, settings: Pharmacy::Settings.current)).to include(urgency_shortfalls: 1)
          expect(jose_encounter.bed_stays).to be_empty
          expect(upa_location.name).to eq("Farmácia da UPA 24h Centro")
        end
      end

      it "nenhuma consulta é finalizada pela semente da observação (nenhum BPA nasce dela)" do
        expect(Consultation.where(id: UrgencyEncounter.where(id: [ ward_encounter(:maria).id, ward_encounter(:benedito).id ]).pluck(:consultation_id)).pluck(:status))
          .to all(eq("draft"))
      end
    end
  end
end

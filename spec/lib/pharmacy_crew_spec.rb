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

# Semente de dev do módulo 27a (ADR 0045) no banco de teste (nunca no de dev),
# com o elenco na ordem do db/seeds.rb até o RegulationCrew (UBS, médica,
# recepção, José, Sebastião e as pessoas dos pedidos de regulação), o catálogo
# de medicamentos pelo caminho real (listas da Anvisa de config/medications e o
# recorte do CATMAT) e a receita controlada ligada. Cada exemplo prova o que a
# prova no navegador precisa achar sem preparo manual. Idempotente; a saída
# nunca leva dado de paciente.
RSpec.describe PharmacyCrew, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { clinical_city!(record_mode: "off", enabled: false) }
  let(:central) { StockLocation.find_by!(kind: "central") }
  let(:pharmacy) { StockLocation.find_by!(kind: "unit") }
  let(:today) { Time.zone.today }

  def build_world!(regulation: true)
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
    described_class.seed_platform!
    CityCatalog.reset_cache!
    Current.city = City.find(city.id)
    CareLinesCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")
    RegulationCrew.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password") if regulation
    ClinicalDocumentsCrew.seed_current_city(slug: "curitiba")
    ControlledPrescriptionsCrew.seed_current_city(slug: "curitiba", password: "dev-password", admin: admin)
  end

  before { build_world! }

  after do
    Rails.cache.clear
    Current.reset
    OtpSender::Test.reset!
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41", password: "dev-password")

  def user(prefix) = User.find_by!(email_address: "#{prefix}@curitiba.demo")

  def item(key) = MedicationCatalogItem.find_by!(catmat_code: described_class::ITEMS.fetch(key)[:code])

  def lot(number) = StockLot.find_by!(lot_number: number)

  def balance(location, lot) = StockMovement.where(stock_location_id: location.id, stock_lot_id: lot.id).sum(:quantity)

  def person(key) = Citizen.find_by!(cpf: RegulationCrew.cpf_for("curitiba", key)).patient

  def jose = Citizen.find_by!(cpf: CareLinesCrew.cpf_for("curitiba", :jose)).patient

  def sebastiao = Citizen.find_by!(cpf: CareLinesCrew.cpf_for("curitiba", :sebastiao)).patient

  def prescription_of(patient, catalog: nil)
    scope = ClinicalDocument.where(kind: "prescription", patient_id: patient.id).joins(:prescription_items)
    scope = scope.where(prescription_items: { medication_catalog_item_id: catalog&.id })
    scope.order(:issued_at).first
  end

  def view(document) = Pharmacy::Prescription.find(kind: "digital", id: document.id, settings: Pharmacy::Settings.current)

  # Tenta dispensar a primeira linha da receita no lote dado, sem gravar nada quando recusa.
  def try_dispense(document, lot, role: "pharmacist", retention: nil, quantity: "10")
    prescription = view(document)
    catalog = Pharmacy::Json.catalog_for(prescription.items.filter_map(&:catalog_item_id))
    Pharmacy::Dispense.call(location: pharmacy, prescription: prescription, retention: retention, by: user("farmacia"), role: role, catalog: catalog,
                            settings: Pharmacy::Settings.current,
                            items: [ { "prescription_item_id" => prescription.items.first.id, "lot_id" => lot.id, "quantity" => quantity } ])
  end

  describe ".seed_platform!" do
    it "dá a forma farmacêutica aos itens (a unidade de dispensação sai certa) e confere as marcas da Anvisa, sem mexer em forma já gravada" do
      forms = described_class::ITEMS.keys.to_h { |key| [ key, Pharmacy::DispensingUnit.for(item(key)) ] }
      expect(forms).to eq(losartana: "comprimido", metformina: "comprimido", sinvastatina: "comprimido", amoxicilina: "cápsula",
                          fluoxetina: "cápsula", diazepam: "comprimido", salbutamol: "frasco")
      expect(item(:fluoxetina)).to have_attributes(controlled: true, controlled_list: "C1")
      expect(item(:diazepam)).to have_attributes(controlled: true, controlled_list: "B1")
      expect(item(:amoxicilina)).to have_attributes(antimicrobial: true, controlled: false)
      expect(item(:losartana)).to have_attributes(antimicrobial: false, controlled: false)
      # A forma que o CATMAT já traz (aerosol) fica como veio.
      expect(item(:salbutamol).dosage_form).to eq("aerosol oral")
      expect { described_class.seed_platform! }.not_to(change { MedicationCatalogItem.order(:catmat_code).pluck(:catmat_code, :dosage_form) })
    end
  end

  describe ".seed_current_city" do
    it "liga o interruptor, cria os dois locais e vincula a equipe: farmacêutica com CBO 223405, auxiliar e o Luiz nos dois locais" do
      result = seed
      unit = HealthUnit.find_by!(name: CareLinesCrew::UNIT)
      aggregate_failures do
        expect(result[:switch]).to eq("ligado (pharmacy)")
        expect(Pharmacy::Gate.usable?(Current.city)).to be(true)
        expect(PharmacySetting.find(1).attributes.slice(*Pharmacy::Catalog::DEFAULT_SETTINGS.keys)).to eq(Pharmacy::Catalog::DEFAULT_SETTINGS)

        expect(central).to have_attributes(name: "Central de Abastecimento Farmacêutico de Curitiba", health_unit_id: nil, active: true)
        expect(pharmacy).to have_attributes(name: "Farmácia da UBS Jardim das Flores", health_unit_id: unit.id, active: true)
        expect(unit.reload.dispenses).to be(true)
        expect(result[:locations]).to eq([ central.name, pharmacy.name ])

        expect(result[:users].map { |u| [ u[:email], u[:role] ] }).to eq(
          [ %w[farmacia@curitiba.demo pharmacist], %w[farmacia.auxiliar@curitiba.demo pharmacy_assistant],
            %w[almoxarifado@curitiba.demo stock_keeper], %w[almoxarifado.2@curitiba.demo stock_keeper] ]
        )
        expect(result[:users].map { |u| u[:otpauth_uri] }).to all(start_with("otpauth://totp/"))

        pharmacist = user("farmacia")
        expect(pharmacist.professional).to have_attributes(professional_name: "Ana Paula Wisniewski", council: "CRF", council_state: "PR")
        expect(Professionals::Cns.valid?(pharmacist.professional.cns)).to be(true)
        expect(CitizenIdentity::Cpf.normalize(pharmacist.professional.cpf)).to be_present
        expect(pharmacist.professional.links.active.pluck(:health_unit_id, :cbo_code)).to eq([ [ unit.id, "223405" ] ])

        roles = ->(email, location) { Pharmacy::Access.roles_at(user: user(email), location: location).to_a }
        expect(roles.call("farmacia", pharmacy)).to eq([ "pharmacist" ])
        expect(roles.call("farmacia", central)).to eq([])
        expect(roles.call("farmacia.auxiliar", pharmacy)).to eq([ "pharmacy_assistant" ])
        expect(roles.call("almoxarifado", central)).to eq([ "stock_keeper" ])
        expect(roles.call("almoxarifado", pharmacy)).to eq([ "stock_keeper" ])
        expect(roles.call("almoxarifado.2", central)).to eq([ "stock_keeper" ])
        expect(roles.call("almoxarifado.2", pharmacy)).to eq([])

        expect(%w[farmacia farmacia.auxiliar almoxarifado almoxarifado.2].map { |email| user(email).otp_secret }).to eq(
          %w[FARMACEUTICASEMENTEDEVCWBAPHARMA AUXILIARFARMACIASEMENTEDEVCWBAPH ALMOXARIFESEMENTEDEVCWBAPHARMACY ALMOXARIFEDOISSEMENTEDEVCWBAPHAR]
        )
        expect(%w[farmacia farmacia.auxiliar almoxarifado almoxarifado.2].map { |email| user(email).mfa_enrolled? }).to all(be(true))
      end
    end

    it "estoque: abertura, nota com conversão de embalagem, três transferências, ajuste pendente, lote vencendo e item abaixo do mínimo" do
      result = seed

      aggregate_failures do
        expect(result[:transfers]).to eq("received" => 1, "received_with_difference" => 1, "sent" => 1)
        expect(result[:adjustments]).to eq("pending" => 1)
        expect(result[:dispensations]).to eq(2)

        # Abertura há 40 dias no central: um por item, dois lotes de losartana.
        expect(StockOpening.where(stock_location_id: central.id).count).to eq(7)
        openings = StockMovement.where(stock_location_id: central.id, kind: "opening")
        expect(openings.count).to eq(8)
        expect(openings.pluck(:recorded_at).map { |at| at.in_time_zone.to_date }.uniq).to eq([ today - 40 ])
        expect(StockLot.where(catalog_item_id: item(:losartana).id).order(:expires_on).pluck(:lot_number, :expires_on))
          .to eq([ [ "LS2411-A", today + 60 ], [ "LS2705-B", today + 540 ], [ "LS2706-C", today + 600 ] ])

        # Nota 000123456: 30 por caixa × 20 caixas, há 20 dias.
        entry = StockEntry.find_by!(stock_location_id: central.id, kind: "invoice", document_number: "000123456")
        expect(entry.supplier).to eq("Distribuidora de Medicamentos Paraná Ltda.")
        movement = StockMovement.find_by!(stock_entry_id: entry.id)
        expect(movement).to have_attributes(kind: "receipt", quantity: 600, package_units: 30, packages: 20, stock_lot_id: lot("LS2706-C").id)
        expect(movement.recorded_at.in_time_zone.to_date).to eq(today - 20)

        # Unidade de dispensação gravada no lote.
        expect(StockLot.pluck(:catmat_code, :dispensing_unit).to_h)
          .to eq(268_856 => "comprimido", 267_690 => "comprimido", 267_747 => "comprimido", 271_089 => "cápsula",
                 273_009 => "cápsula", 267_197 => "comprimido", 294_887 => "frasco")

        # Transferências: inteira (há 30 dias), com diferença (há 10) e em trânsito (hoje).
        by_status = StockTransfer.all.index_by(&:status)
        expect(by_status.values.map { |t| [ t.from_location_id, t.to_location_id ] }.uniq).to eq([ [ central.id, pharmacy.id ] ])
        expect(by_status.fetch("received").sent_at.in_time_zone.to_date).to eq(today - 30)
        difference = by_status.fetch("received_with_difference")
        expect(difference.sent_at.in_time_zone.to_date).to eq(today - 10)
        expect(difference.items.map { |i| [ i.stock_lot_id, i.quantity_sent, i.quantity_received ] }).to eq([ [ lot("LS2706-C").id, 300, 240 ] ])
        expect(difference.items.sole.difference_reason).to eq("Duas caixas avariadas no transporte")
        expect(StockMovement.where(stock_transfer_id: difference.id, kind: "loss").sole).to have_attributes(quantity: -60, stock_location_id: pharmacy.id)
        expect(by_status.fetch("sent").items.map { |i| [ i.stock_lot_id, i.quantity_sent ] }).to eq([ [ lot("MF2702-A").id, 300 ] ])
        expect(by_status.fetch("sent").sent_at.in_time_zone.to_date).to eq(today)

        # Ajuste pendente de 20% (contagem de SINVASTATINA) no central, pedido pelo Luiz.
        adjustment = StockAdjustment.sole
        expect(adjustment).to have_attributes(status: "pending", kind: "adjustment", stock_location_id: central.id, stock_lot_id: lot("SV2705-A").id,
                                              counted_quantity: 480, balance_at_request: 600, quantity: -120, requested_by_user_id: user("almoxarifado").id)

        # Alertas: lote vencendo em 60 dias (alerta de 90), mínimo de metformina acima do saldo, trânsito e ajuste.
        settings = Pharmacy::Settings.current
        expect(Pharmacy::Alerts.call(location: central, today: today, settings: settings))
          .to eq(expiring: 1, expired: 0, below_minimum: 0, in_transit: 0, pending_adjustments: 1)
        expect(Pharmacy::Alerts.call(location: pharmacy, today: today, settings: settings))
          .to eq(expiring: 0, expired: 0, below_minimum: 1, in_transit: 1, pending_adjustments: 0)
        expect(StockMinimum.find_by!(stock_location_id: pharmacy.id, catalog_item_id: item(:metformina).id).minimum).to eq(600)
        expect(balance(pharmacy, lot("MF2702-A"))).to eq(400)

        # Saldo de nenhum (local, lote) fica negativo.
        expect(StockMovement.group(:stock_location_id, :stock_lot_id).sum(:quantity).values.min).to be >= 0
      end
    end

    it "uso contínuo: o José retirou há 26 dias (próxima retirada liberada) e o Sebastião há 10 (cedo demais, só daqui a 15 dias)" do
      seed
      settings = Pharmacy::Settings.current
      jose_doc = prescription_of(jose, catalog: item(:losartana))
      sebastiao_doc = prescription_of(sebastiao, catalog: item(:losartana))

      aggregate_failures do
        expect([ jose_doc, sebastiao_doc ].map(&:status)).to eq(%w[issued issued])
        expect([ jose_doc, sebastiao_doc ].map { |doc| doc.prescription_items.map(&:continuous) }).to eq([ [ true ], [ true ] ])
        expect(Dispensation.where(clinical_document_id: jose_doc.id).sole.dispensed_at.in_time_zone.to_date).to eq(today - 26)
        expect(Dispensation.where(clinical_document_id: sebastiao_doc.id).sole.dispensed_at.in_time_zone.to_date).to eq(today - 10)

        last = ->(doc) { Pharmacy::Dispensed.summary(view(doc)).values.sole[:last_on] }
        expect(last.call(jose_doc) + settings.continuous_interval_days).to be <= today
        expect(last.call(sebastiao_doc) + settings.continuous_interval_days).to eq(today + 15)

        refused = try_dispense(sebastiao_doc, lot("LS2705-B"))
        expect([ refused.reason, refused.details[:problems].map { |p| p[:error] } ]).to eq([ :too_early, %w[too_early] ])
        expect(refused.details[:problems].first[:next_allowed_on]).to eq((today + 15).iso8601)
        expect(Dispensation.count).to eq(2)
        # Quem retirou: o José com a auxiliar, o Sebastião com a farmacêutica.
        expect(Dispensation.where(clinical_document_id: jose_doc.id).sole).to have_attributes(dispensed_by_role: "pharmacy_assistant", retained: false)
        expect(Dispensation.where(clinical_document_id: sebastiao_doc.id).sole).to have_attributes(dispensed_by_role: "pharmacist", retained: false)
      end
    end

    it "receitas da prova: cancelada, texto livre, antimicrobiano válido e vencido, controle especial de FLUOXETINA e externa de DIAZEPAM B1" do
      result = seed
      expect(result[:skipped]).to eq([])
      lot_amoxicilina = lot("AM2701-A")

      aggregate_failures do
        cancelled = prescription_of(person(:valdir), catalog: item(:losartana))
        expect(cancelled).to have_attributes(status: "cancelled", cancelled_by_user_id: user("profissional").id)
        expect(try_dispense(cancelled, lot("LS2705-B")).reason).to eq(:prescription_cancelled)

        free = prescription_of(person(:iolanda), catalog: nil)
        expect(free.prescription_items.sole).to have_attributes(medication_catalog_item_id: nil, free_text: be_present)
        expect(try_dispense(free, lot("SV2705-A")).details[:problems].map { |p| p[:path] }).to eq([ "items[0].catalog_item_id" ])
        expect(try_dispense(free, lot("SV2705-A"), role: "pharmacy_assistant").reason).to eq(:free_text_requires_pharmacist)

        # Antimicrobiano válido (Paulo, há 3 dias): a retenção é obrigatória, auxiliar ou farmacêutico.
        valid = prescription_of(person(:paulo), catalog: item(:amoxicilina))
        expect(valid.content_data).to include("category" => "antimicrobial", "antimicrobial" => true)
        expect(valid.prescription_items.sole.antimicrobial).to be(true)
        expect(view(valid).items.sole).to have_attributes(antimicrobial: true, controlled: false, retention_required: true)
        expect(try_dispense(valid, lot_amoxicilina, role: "pharmacy_assistant").details[:problems].map { |p| p[:error] }).to eq(%w[retention_required])
        expect(Dispensation.where(clinical_document_id: valid.id)).to be_empty

        # Antimicrobiano comum emitido há 40 dias (Márcia): vencido.
        expired = prescription_of(person(:marcia), catalog: item(:amoxicilina))
        expect(expired.issued_at.in_time_zone.to_date).to eq(today - 40)
        expect(try_dispense(expired, lot_amoxicilina).details[:problems].map { |p| p[:error] }).to include("prescription_expired")

        # Controle especial (Roberto): só a farmacêutica, com retenção.
        special = prescription_of(person(:roberto), catalog: item(:fluoxetina))
        expect(special.content_data).to include("category" => "special_control")
        # A médica de dev não tem certificado ligado: papel, sem número SNCR.
        expect(special).to have_attributes(issue_mode: "paper")
        expect(special.content_data["sncr"]).to be_nil
        expect(view(special).items.sole).to have_attributes(controlled: true, controlled_list: "C1", retention_required: true)
        expect(try_dispense(special, lot("FL2704-A"), role: "pharmacy_assistant").reason).to eq(:controlled_requires_pharmacist)
        expect(try_dispense(special, lot("FL2704-A")).details[:problems].map { |p| p[:error] }).to eq(%w[retention_required])
        expect(Dispensation.where(clinical_document_id: special.id)).to be_empty

        # Receita externa de DIAZEPAM B1 no UBS, para paciente sem CPF.
        external = ExternalPrescription.sole
        expect(external).to have_attributes(stock_location_id: pharmacy.id, notification_number: "PR-2026-000777", council: "CRM", council_state: "PR")
        expect(external.items.sole).to have_attributes(catalog_item_id: item(:diazepam).id, controlled_list: "B1")
        expect(external.patient).to have_attributes(cpf: nil, no_cpf_reason: "5")
        expect(Pharmacy::Prescription.find(kind: "external", id: external.id, settings: Pharmacy::Settings.current).items.sole)
          .to have_attributes(controlled: true, retention_required: true)
        expect(Dispensation.where(external_prescription_id: external.id)).to be_empty
      end
    end

    it "a segunda rodada não cria nada: nem movimento, transferência, ajuste, dispensação, receita, usuário ou vínculo" do
      first = seed
      tables = [ User, Membership, Professional, ProfessionalLink, StockLocation, StockLocationStaff, StockLot, StockEntry, StockOpening, StockMovement,
                 StockTransfer, StockTransferItem, StockAdjustment, StockMinimum, Dispensation, DispensationItem, ExternalPrescription,
                 ExternalPrescriptionItem, ClinicalDocument, PrescriptionItem, Patient, DomainEvent ]
      expect { expect(seed).to eq(first) }.not_to(change { tables.map(&:count) })
      expect(first[:transfers]).to eq("received" => 1, "received_with_difference" => 1, "sent" => 1)
      expect(first[:adjustments]).to eq("pending" => 1)
    end

    it "retoma o que a prova mexeu: transferência em trânsito já recebida e ajuste já aprovado não voltam" do
      seed
      sent = StockTransfer.find_by!(status: "sent")
      received = Pharmacy::ReceiveTransfer.call(transfer: sent, by: user("almoxarifado"),
                                                items: sent.items.map { |i| { "lot_id" => i.stock_lot_id, "quantity_received" => i.quantity_sent.to_s("F") } })
      expect(received).to be_ok
      approved = Pharmacy::DecideAdjustment.call(adjustment: StockAdjustment.sole, decision: "approve", reason: nil, by: user("almoxarifado.2"))
      expect(approved).to be_ok

      result = nil
      expect { result = seed }.not_to(change { [ StockTransfer.count, StockAdjustment.count, StockMovement.count, Dispensation.count ] })
      expect(result[:transfers]).to eq("received" => 2, "received_with_difference" => 1)
      expect(result[:adjustments]).to eq("approved" => 1)
    end

    it "a saída: só e-mail, papel e otpauth — nunca CPF, CNS, nome nem código de receita de paciente" do
      result = seed
      lines = described_class.summary_lines(result, password: "dev-password")
      text = ([ lines ] + [ result.inspect ]).join("\n")
      patients = [ jose, sebastiao ] + %i[valdir iolanda paulo marcia roberto].map { |key| person(key) } + [ ExternalPrescription.sole.patient ]
      codes = ClinicalDocument.where(kind: "prescription").pluck(:short_code)

      expect(text).to include("farmacia@curitiba.demo (pharmacist)", "almoxarifado.2@curitiba.demo (stock_keeper)", "otpauth://")
      expect(patients.map(&:full_name).select { |name| text.include?(name) }).to eq([])
      expect(patients.filter_map(&:cpf).select { |cpf| text.include?(cpf) }).to eq([])
      expect(patients.filter_map(&:cns).select { |cns| text.include?(cns) }).to eq([])
      expect(codes.select { |code| text.include?(code) }).to eq([])
      expect(text).not_to include("PR-2026-000777")
    end

    it "sem controlled_prescriptions em Curitiba, a FLUOXETINA é pulada e a saída diz por quê; o resto segue" do
      Platform::Features.set!(city: City.find(Current.city.id), key: "controlled_prescriptions", enabled: false, maintainer: Maintainer.find_by!(email_address: "dev@local"))
      result = seed

      expect(result[:skipped]).to eq([ "receita de FLUOXETINA (controle especial): controlled_prescriptions desligado" ])
      expect(described_class.summary_lines(result, password: "dev-password").join("\n")).to include("pulado: receita de FLUOXETINA", "controlled_prescriptions desligado")
      expect(ClinicalDocument.joins(:prescription_items).where(prescription_items: { medication_catalog_item_id: item(:fluoxetina).id })).to be_empty
      expect(result[:dispensations]).to eq(2)
      expect(ExternalPrescription.count).to eq(1)
    end

    it "o José com óbito registrado: a receita dele é pulada, o resto da semente segue e a saída diz por quê" do
      nurse = User.find_by!(email_address: "enfermeira@curitiba.demo")
      enrollment = CareLineEnrollment.active_enrollments.find_by!(patient_id: jose.id)
      expect(CareLines::EndEnrollment.call(enrollment: enrollment, reason: "death", note: nil, by: nurse)).to be_ok

      result = nil
      expect { result = seed }.to output(/farmácia: .*pedido 6/).to_stderr
      expect(result[:skipped]).to eq([ "receita de uso contínuo do pedido 6 da regulação: óbito registrado" ])
      expect(result[:dispensations]).to eq(1)
      expect(prescription_of(sebastiao, catalog: item(:losartana))).to be_present
    end

    it "sem o mantenedor de dev não liga nada" do
      allow(Maintainer).to receive(:find_by).with(email_address: "dev@local").and_return(nil)
      result = nil
      expect { result = seed }.to output(/sem mantenedor de dev/).to_stderr
      expect(result).to include(switch: "desligado (sem mantenedor dev@local)", users: [])
      expect([ StockLocation.count, StockLot.count, User.exists?(email_address: "farmacia@curitiba.demo") ]).to eq([ 0, 0, false ])
    end

    it "fora de Curitiba não liga nada" do
      expect(described_class.seed_current_city(slug: "maringa", ddd: "44")).to include(switch: "fora", users: [])
      expect(Pharmacy::Gate.usable?(Current.city)).to be(false)
      expect(StockLocation.count).to eq(0)
    end

    it "em ambiente implantado recusa semear" do
      allow(Rota).to receive(:deployed?).and_return(true)
      expect { seed }.to raise_error(/ambiente implantado/)
      expect { described_class.seed_platform! }.to raise_error(/ambiente implantado/)
    end
  end
end

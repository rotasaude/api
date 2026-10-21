require "rails_helper"
require Rails.root.join("lib/billing_crew").to_s

# Semente de dev do módulo 22 (ADR 0039; dev imita o real): UPA de Curitiba
# com CNES, produção faturável e não faturável na UPA, produção da UBS
# (nunca BPA), do laboratório municipal (BPA-C; liberador sem vínculo =
# pendência), configuração e faturista com TOTP. Idempotente; fora de
# Curitiba não liga nada.
RSpec.describe BillingCrew do
  include ActiveSupport::Testing::TimeHelpers

  before do
    travel_to(Time.zone.local(Time.zone.today.year, Time.zone.today.month, 15, 12, 0, 0))
    billing_city!(lab: true)
    Platform::Features.set!(city: Current.city, key: "procedure_billing", enabled: false, maintainer: ledi_maintainer!)
    Maintainer.find_by(email_address: "dev@local") ||
      Maintainer.create!(email_address: "dev@local", password: "dev-password-123", otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    upa = HealthUnit.create!(name: BillingCrew::UPA, kind: "upa")
    ubs = HealthUnit.create!(name: BillingCrew::UBS, kind: "ubs")
    doctor = staff_with("profissional@curitiba.demo", "health_professional")
    link_professional!(doctor, upa, cbo: "225124")
    link_professional!(doctor, ubs, cbo: "225125")
    link_professional!(staff_with("tecnico@curitiba.demo", "health_professional"), upa, cbo: "322205")
    lab = ExamProvider.create!(name: BillingCrew::LAB, kind: "municipal", uses_municipal_lab: true, cnes: "2385123")
    bio = lab_releaser!(lab, lead: true).tap { |u| u.update!(email_address: "biomedica@curitiba.demo") }
    link_professional!(bio, ubs, cbo: "221205")
    lab_releaser!(lab, council: "CRM", deputy: true).update!(email_address: "patologista@curitiba.demo")
    3.times { billing_patient!(demographics: false) }
  end

  after { travel_back }

  def seed = described_class.seed_current_city(slug: "curitiba", password: "dev-password", admin: lab_admin!)

  it "liga, dá CNES à UPA, semeia a produção e o faturista; a segunda rodada não muda nada" do
    result = seed
    upa = HealthUnit.find_by!(name: BillingCrew::UPA)
    expect(Billing::Gate.enabled?(Current.city)).to be(true)
    expect(upa.cnes).to eq((Zlib.crc32("cnes:curitiba:#{BillingCrew::UPA}") % 9_000_000 + 1_000_000).to_s)
    at_upa = PerformedProcedure.where(health_unit_id: upa.id)
    expect(at_upa.where(billable: true).distinct.pluck(:instrument)).to match_array(%w[bpa_i bpa_c])
    expect(at_upa.pluck(:blocking_reasons).flatten).to include("cid_required", "cbo_not_allowed")
    expect(at_upa.distinct.pluck(:billing_competence)).to match_array([ Time.zone.today.strftime("%Y%m"), (Time.zone.today << 1).strftime("%Y%m") ])
    ubs = PerformedProcedure.where(health_unit_id: HealthUnit.find_by!(name: BillingCrew::UBS).id)
    expect(ubs.pluck(:blocking_reasons).uniq).to eq([ %w[establishment_is_aps] ])
    expect(ubs.pluck(:billing_period_id).uniq).to eq([ nil ])
    lab = PerformedProcedure.where(exam_provider_id: ExamProvider.find_by!(name: BillingCrew::LAB).id)
    expect(lab.where(billable: true).pluck(:instrument).uniq).to eq(%w[bpa_c])
    expect(lab.pluck(:blocking_reasons).flatten).to include("missing_professional_cbo")
    clerk = User.find_by!(email_address: "faturista@curitiba.demo")
    expect(clerk.has_role?("billing_clerk")).to be(true)
    expect(clerk.reload.mfa_enrolled?).to be(true)
    expect(BillingSetting.current).to have_attributes(origin_name: "SMS Curitiba", origin_acronym: "SMS", management: "M")
    expect(result[:users].map { |u| u[:email] }).to eq([ "faturista@curitiba.demo" ])
    first, second, third = Patient.order(:created_at, :id).limit(3).to_a
    expect([ first.race_color, second.race_color, second.ethnicity, third.race_color ]).to eq([ "03", "05", "0001", nil ])
    period = BillingPeriod.find_by!(health_unit_id: upa.id, competence: Time.zone.today.strftime("%Y%m"))
    expect(Billing::Pending.call(period).flat_map { |i| i[:reasons] }).to include("missing_race_color", "missing_address")
    expect { seed }.not_to(change { [ PerformedProcedure.count, BillingPeriod.count, Membership.count, BillingSetting.count ] })
  end

  it "fora de Curitiba não liga nada" do
    expect(described_class.seed_current_city(slug: "maringa", password: "x", admin: lab_admin!)[:switch]).to start_with("desligado")
    expect(PerformedProcedure.count).to eq(0)
  end
end

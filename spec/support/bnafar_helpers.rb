require "net/http"
require_relative "../../lib/fake_bnafar/app"

# spec/support/bnafar_helpers.rb
# Módulo 27b: o SI-BNAFAR simulado (FakeBnafar::App) servido por WebMock#to_rack
# em http://fake-bnafar.test:8095. Nenhuma spec bate em URL real. Os demais
# helpers do módulo entram nas tasks seguintes (Task 10: lote completo,
# perda pelo razão e saída já ligada; Task 11: credencial e envio ligado).
FAKE_BNAFAR_BASE = "http://fake-bnafar.test:8095".freeze

module BnafarHelpers
  # Liga o simulado (um novo, ou o passado) à base de teste e devolve a instância.
  def fake_bnafar!(app = FakeBnafar::App.new)
    stub_request(:any, /\A#{Regexp.escape(FAKE_BNAFAR_BASE)}/).to_rack(app)
    app
  end

  # Task 10: CNPJ válido de teste (formato da Receita, com os dígitos).
  def bnafar_cnpj = Cnpj.with_check_digits("11222333000181"[0, 12])

  # Completa os dados BNAFAR do lote direto na linha (o guard do lote pede
  # bnafar_version + 1). A vacina não leva CNPJ (Q21: vem do YAML).
  def bnafar_complete!(lot, **over)
    attrs = { unit_price_cents: 1990, anvisa_registration: "1234567890123", health_program: "AFB" }
    attrs[:manufacturer_cnpj] = bnafar_cnpj unless lot.immunobiological?
    lot.update_columns(attrs.merge(over).merge(bnafar_version: lot.bnafar_version + 1))
    lot.reload
  end

  # Perda (ou vencimento com `loss_code`) aplicada pelo razão, com o relógio do
  # movimento em `at` (o `created_at` é o relógio da chamada). -> StockMovement
  def bnafar_loss!(location, lot, quantity, at: Time.current, loss_code: nil, by: pharmacy_admin!)
    balance = StockMovement.where(stock_location_id: location.id, stock_lot_id: lot.id).sum(:quantity)
    adjustment = StockAdjustment.create!(stock_location: location, stock_lot: lot, kind: "loss", status: "applied", quantity: -quantity,
                                         loss_code: loss_code, balance_at_request: balance, reason: "Frascos quebrados no transporte",
                                         requested_by_user: by)
    Pharmacy::Ledger.record!(location: location, lot: lot, kind: "loss", quantity: quantity, by: by, document: adjustment,
                             reason: "Frascos quebrados no transporte", at: at)
  end

  # Registro aceito de uma saída já enviada e o link do movimento a ele.
  # -> BnafarMovementLink
  def bnafar_link!(movement, kind: "exit", reference_on: movement.created_at.to_date, bnafar_code: rand(1..999_999))
    submission = BnafarSubmission.find_or_create_by!(reference_on: reference_on, subject: "exit", environment: "production") do |created|
      created.status = "finished" # a remessa já enviada (R10: o delete não a reabre)
      created.finished_at = Time.current
    end
    record = BnafarRecord.create!(bnafar_submission: submission, origin_code: SecureRandom.uuid, subject: "exit",
                                  stock_location_id: movement.stock_location_id, item_key: "test:#{movement.stock_lot_id}",
                                  payload: "{}")
    record.update_columns(status: "accepted", accepted_at: Time.current, sent_at: Time.current, bnafar_code: bnafar_code)
    BnafarMovementLink.create!(stock_movement: movement, bnafar_record: record, kind: kind)
  end

  # Task 11: credencial BNAFAR do ambiente (usuário e senha de teste).
  def bnafar_credential!(environment: "production", status: nil)
    IntegrationCredential.create!(kind: "bnafar", environment: environment,
                                  secret: { "username" => "usuario-bnafar", "password" => "senha-bnafar" },
                                  set_by_user: pharmacy_admin!, set_at: Time.current, last_check_status: status)
  end

  # Task 11: o envio utilizável (credencial de produção, IBGE, `bnafar` e os
  # domínios), ligado desde `since` (Gate.domains_through); com `mock`, o
  # simulado no FAKE_BNAFAR_BASE (use com fake_bnafar!).
  def bnafar_on!(city, since: Time.current, domains: %w[bnafar_medications], mock: false)
    profile = city_profile!
    profile.update!(ibge_code: "4106902") if profile.ibge_code.blank?
    bnafar_credential!
    BnafarSetting.ensure_defaults!
    maintainer = ledi_maintainer!
    keys = [ Bnafar::Gate::KEY, *domains ]
    keys << Bnafar::Mock::KEY if mock
    keys.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
    CityFeature.where(city_id: city.id, key: keys).update_all(changed_at: since)
    CityCatalog.reset_cache!
    return unless mock

    Bnafar::Client.reset_cache!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_BNAFAR_URL").and_return(FAKE_BNAFAR_BASE)
  end
end

RSpec.configure { |c| c.include BnafarHelpers }

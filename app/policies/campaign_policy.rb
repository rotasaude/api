# Campanhas (ADR 0024; spec 2026-09-29 §6.1): o campaign_manager monta, agenda,
# cancela e envia; a chave de SMS da cidade é lida por ele e pelo
# municipal_admin, e só o municipal_admin a muda.
class CampaignPolicy < ApplicationPolicy
  def manage?
    role?(:campaign_manager)
  end

  def read_sms_setting?
    role?(:campaign_manager) || role?(:municipal_admin)
  end

  def write_sms_setting?
    role?(:municipal_admin)
  end
end

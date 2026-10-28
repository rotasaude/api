# Lista municipal do que o enfermeiro (CBO 2235*) pode pedir à regulação
# (ADR 0044). Configuração: o item sai e volta.
class NurseRequestableItem < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"
end

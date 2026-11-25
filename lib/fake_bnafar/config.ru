# lib/fake_bnafar/config.ru
# SI-BNAFAR SIMULADO do compose de dev (módulo 27b). Nunca em produção.
require_relative "app"

abort "fake-bnafar nunca sobe em produção" if (ENV["RAILS_ENV"] || ENV["RACK_ENV"]).to_s == "production"

run FakeBnafar::App.new

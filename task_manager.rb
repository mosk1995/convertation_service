# Основной файл демона конвертации, на него можно натравливать systemd.

require 'figaro'
require_relative 'config/environment'
require "#{ENV['root']}/config/common_requirement"

task_mgr_logger = Logger.new("#{ENV['root']}/log/task_mgr.log")

# отбор модулей способных сконвертировать задачу
def modules_for_task task, registered_modules
  modules = []
  registered_modules.each do |reg_mod|
    if reg_mod.valid_combinations[:from].include?(task.input_extension) &&
        reg_mod.valid_combinations[:to].include?(task.output_extension)
      modules << reg_mod
    end
  end
  modules
end

launched_modules = Hash.new
launched_tasks = Hash.new

loop do
  unconverted_tasks = ConvertTask.filter(state: ConvertState::RECEIVED).order(:created_at).all
  convert_modules = ConvertModulesLoader::ConvertModule.modules

  prepared_tasks = unconverted_tasks.inject({}) do |prepared_tasks, task|
    modules = modules_for_task(task, convert_modules)
    if modules.any?
      prepared_tasks.merge!({task => modules})
    else
      DB.transaction do
        task.update(errors: I18n.t(:modules_not_exist, scope: 'convert_task.error'))
      end
      task_mgr_logger.error I18n.t(:modules_not_exist,
                                   scope: 'task_manager_logger.error',
                                   input_extension: task.input_extension,
                                   output_extension: task.output_extension,
                                   id: task.id)
      prepared_tasks
    end
  end

  # пока запускаем первый попавшийся не занятый модуль из доступных для задачи
  # в идеале, "равномерное" раскидывание задач по модулям
  # с учётом времени поступления задачи
  # переменная класса

  prepared_tasks.each do |task, modules|
    conv_module = modules.first
    unless launched_modules.has_key? conv_module
      launched_modules[conv_module] = 0
    end
    value = launched_modules[conv_module]
    if value < conv_module.max_launched_modules
      launched_modules[conv_module] += 1
      DB.transaction do
        task.update(state: ConvertState::PROCEED)
      end
      input_filename = task.source_file
      result_filename = input_filename.gsub(File.extname(input_filename), "") << ".#{task.output_extension}"
      convert_options = {output_extension: task.output_extension,
                         output_dir: ENV['file_storage'],
                         source_path: "#{ENV['file_storage']}/#{input_filename}",
                         destination_path: "#{ENV['file_storage']}/#{result_filename}"
      }

      launched_tasks[task] = -1
      Thread.new do
        launched_tasks[task] = conv_module.run(convert_options)
        launched_modules[conv_module] -= 1
      end
    end
  end

  finished_tasks = launched_tasks.select { |_task, state| state != -1 }
  finished_tasks.each do |task, state|
    if state
      result_filename = task.source_file.gsub(File.extname(task.source_file), "") << ".#{task.output_extension}"
      DB.transaction do
        task.updated_at = Time.now
        task.state = ConvertState::FINISHED
        task.converted_file = result_filename
        task.result_file_sha256 = Digest::SHA256.file("#{ENV['file_storage']}/#{result_filename}").hexdigest
        task.finished_at = Time.now
        task.save
      end
    else
      DB.transaction do
        task.update(state: ConvertState::ERROR)
      end
      task_mgr_logger.error I18n.t(:fail_convert,
                                   scope: 'task_manager_logger.error',
                                   id: task.id)
    end
    launched_tasks.delete(task)
  end
  sleep 0.5
end

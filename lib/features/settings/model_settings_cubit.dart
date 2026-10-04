// ModelSettingsCubit — state manager pilihan model user.
//
// Sumber kebenaran: SharedPreferences key [selectedModelIdKey]. Saat app
// launch, pilihan dimuat dari storage; bila kosong, fallback ke
// [ModelRegistry.defaultModel] (LFM 2.5 350M).
//
// Dipakai bersama oleh UI Model Picker (rebuild via BlocBuilder) dan
// inisialisasi model (`LlmInference.initialize`) agar model yang dimuat
// sesuai pilihan yang tersimpan, bukan string hardcode.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/model_registry.dart';

class ModelSettingsCubit extends Cubit<ModelInfo> {
  ModelSettingsCubit._() : super(ModelRegistry.defaultModel);

  /// Shared app-wide (mengikuti pola singleton ModelDownloadService) supaya
  /// bisa diakses dari sheet picker, chat cubit, dan inisialisasi LLM tanpa
  /// harus melewati BlocProvider di pohon widget.
  static final ModelSettingsCubit instance = ModelSettingsCubit._();

  @visibleForTesting
  factory ModelSettingsCubit.create() => ModelSettingsCubit._();

  static const selectedModelIdKey = 'selected_model_id';

  /// Muat pilihan tersimpan; fallback ke default bila storage kosong atau id
  /// tidak dikenal registry. Dipanggil sekali saat app start.
  Future<void> load() async {
    emit(await getSelectedModel());
  }

  /// Pilih model baru → persist id ke SharedPreferences lalu emit.
  Future<void> selectModel(ModelInfo model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(selectedModelIdKey, model.id);
    emit(model);
  }

  /// Baca pilihan aktif langsung dari storage (tanpa menyentuh state cubit).
  static Future<ModelInfo> getSelectedModel() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(selectedModelIdKey);
    return ModelRegistry.byId(id) ?? ModelRegistry.defaultModel;
  }
}

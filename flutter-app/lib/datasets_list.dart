// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// import 'package:automl_mlkit/automl_mlkit.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:firebase_ml_custom/firebase_ml_custom.dart';
import 'package:tflite/tflite.dart';
import 'package:image/image.dart' as img;
import 'labelscreen.dart';
import 'models.dart';
import 'storage.dart';
import 'user_model.dart';
import 'widgets/zerostate_datasets.dart';

class DatasetsList extends StatelessWidget {
  final Query query;
  final UserModel model;
  final GlobalKey<ScaffoldState> scaffoldKey;

  const DatasetsList({Key key, this.query, this.model, this.scaffoldKey})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return new StreamBuilder(
      stream: query.snapshots(),
      builder: (BuildContext context, AsyncSnapshot<QuerySnapshot> snapshot) {
        if (snapshot.hasError) {
          return new Text('Error: ${snapshot.error}');
        }
        switch (snapshot.connectionState) {
          case ConnectionState.waiting:
            return Center(child: new CircularProgressIndicator());
          default:
            if (snapshot.data.docs.isEmpty) {
              return ZeroStateDatasets();
            }

            final filteredDatasets = snapshot.data.docs
                .map(Dataset.fromDocument)
                .where((dataset) =>
                    dataset.isPublic ||
                    dataset.isOwner(model) ||
                    dataset.isCollaborator(model));

            if (filteredDatasets.isEmpty) {
              return ZeroStateDatasets();
            }

            return ListView(
                children: filteredDatasets
                    .map(
                      (dataset) => new Container(
                        decoration: new BoxDecoration(
                          border: Border(
                              bottom: BorderSide(color: Colors.grey[300])),
                        ),
                        height: 100,
                        child: InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    new ListLabelsScreen(dataset),
                              ),
                            );
                          },
                          child:
                              new DatasetActions(dataset, model, scaffoldKey),
                        ),
                      ),
                    )
                    .toList());
        }
      },
    );
  }
}

const Map<String, String> MANIFEST_JSON_CONTENTS = {
  "modelFile": "model.tflite",
  "labelsFile": "dict.txt",
  "modelType": "IMAGE_LABELING"
};

class DatasetActions extends StatelessWidget {
  // Firestore id of the dataset for which model status is requested
  final Dataset dataset;
  final UserModel model;
  final GlobalKey<ScaffoldState> scaffoldKey;

  void _showSnackBar(String text) {
    scaffoldKey.currentState.showSnackBar(SnackBar(content: new Text(text)));
  }

  const DatasetActions(this.dataset, this.model, this.scaffoldKey);

  Future _beginModelInferenceAsync(BuildContext context) async {
    _showSnackBar("Fetching latest model info");
    final autoMlStorage = InheritedStorage.of(context).autoMlStorage;
    try {
      await _downloadModel(dataset, autoMlStorage);
      print("Successfully downloaded the model");
    } catch (e) {
      _showSnackBar("Error downloading model");
      print(e);
    }
    // try {
    //   await loadModel(dataset.automlId);
    //   print("Successfully loaded the model");
    // } catch (e) {
    //   _showSnackBar("Error loading the model");
    //   print(e);
    // }
    await _getImageAndRunInferenceAsync(context);
  }

  Future _getImageAndRunInferenceAsync(BuildContext context) async {
    final image = await getImage();
    final List inferences = await recognizeImage(image);

    // for debugging
    inferences.forEach((i) {
      print(("[Inference results] infer: ${i.toString()}"));
    });
    await _showInferenceDialog(context, inferences, image);
  }

  Future<void> _showInferenceDialog(
      BuildContext context, List<dynamic> inferences, File image) async {
    final retryInference = await showDialog<bool>(
        context: scaffoldKey.currentContext,
        builder: (BuildContext context) => InferenceDialog(image, inferences));

    // allow user to pick another image and retry inference
    if (retryInference) {
      await _getImageAndRunInferenceAsync(context);
    }
  }

  IconData getIcon(Dataset dataset) {
    if (dataset.isOwner(model)) {
      return Icons.person;
    }
    if (dataset.isCollaborator(model)) {
      return Icons.people;
    }
    if (dataset.isPublic) {
      return Icons.public;
    }
  }

  String sharingLabel(Dataset dataset) {
    if (dataset.isOwner(model)) {
      return "Private";
    }
    if (dataset.isCollaborator(model)) {
      return "Shared";
    }
    if (dataset.isPublic) {
      return "Public";
    }
  }

  Color getColor(Dataset dataset) {
    if (dataset.isOwner(model)) {
      return Colors.teal;
    }
    if (dataset.isCollaborator(model)) {
      return Colors.pink[400];
    }
    if (dataset.isPublic) {
      return Colors.indigo;
    }
  }

  @override
  Widget build(BuildContext context) {
    bool modelExists = false;
    String modelStatus = "No model available";

    return new StreamBuilder(
      stream: FirebaseFirestore.instance
          .collection("models")
          .where("dataset_id", isEqualTo: dataset.automlId)
          .orderBy("generated_at", descending: true)
          .snapshots(),
      builder: (BuildContext context, AsyncSnapshot<QuerySnapshot> snapshot) {
        // if (!snapshot.hasData) return new Text(modelStatus);

        if (snapshot.hasData && snapshot.data.docs.isNotEmpty) {
          final modelInfo = snapshot.data.docs.first;
          final generatedAt =
              DateTime.fromMillisecondsSinceEpoch(modelInfo["generated_at"]);
          final ago = timeago.format(generatedAt);
          modelExists = true;
          modelStatus = "Last trained: " + ago;
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          getIcon(dataset),
                          size: 14,
                          color: Colors.black54,
                        ),
                        SizedBox(width: 4),
                        new Text(
                          dataset.name.toUpperCase(),
                          style: TextStyle(
                            fontSize: 14,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: <Widget>[
                          new Text(
                            dataset.description,
                            style: TextStyle(color: Colors.black54),
                          ),
                          new Text(
                            '\u00B7',
                            style: TextStyle(
                              color: Colors.black54,
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                            ),
                          ),
                          new Text(
                            sharingLabel(dataset),
                            style: TextStyle(color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                    ModelStatusInfo(
                      dataset: dataset,
                      modelStatus: modelStatus,
                      doesModelExist: modelExists,
                    )
                  ],
                ),
              ),
              new Row(
                children: <Widget>[
                  if (modelExists)
                    Container(
                      child: IconButton(
                        color: Colors.deepPurple,
                        icon: Icon(Icons.center_focus_weak),
                        tooltip: 'Run inference on an image',
                        onPressed: () async {
                          await _beginModelInferenceAsync(context);
                        },
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black12, width: 1.0),
                        shape: BoxShape.circle,
                      ),
                    )
                ],
              )
            ],
          ),
        );
      },
    );
  }

  // Future loadModel(String dataset) async {
  //   try {
  //     // await AutomlMlkit.loadModelFromCache(dataset: dataset);
  //     print("Model successfully loaded");
  //   } on PlatformException catch (e) {
  //     print("failed to load model");
  //     print(e.toString());
  //   }
  // }

  Future getImage() async {
    return ImagePicker.pickImage(source: ImageSource.gallery);
  }

  Uint8List imageToByteListUint8(img.Image image, int inputSize) {
    print("entro1");
    var convertedBytes = Uint8List(1 * inputSize * inputSize * 3);
    var buffer = Uint8List.view(convertedBytes.buffer);
    int pixelIndex = 0;
    for (var i = 0; i < inputSize; i++) {
      for (var j = 0; j < inputSize; j++) {
        var pixel = image.getPixel(j, i);
        buffer[pixelIndex++] = img.getRed(pixel);
        buffer[pixelIndex++] = img.getGreen(pixel);
        buffer[pixelIndex++] = img.getBlue(pixel);
      }
    }
    print("entro2");
    return convertedBytes.buffer.asUint8List();
  }

  Future<List<dynamic>> recognizeImage(File image) async {
    // sampleImage.readAsBytes()
    // final results =
    //     await Tflite.runModelOnBinary(binary: image.readAsBytesSync());
    // final results = await Tflite.detectObjectOnImage(path: image.path);
    print("recognize");
    var imageBytes = (await rootBundle.load(image.path)).buffer;
    print("recognize2");
    img.Image oriImage = img.decodeJpg(imageBytes.asUint8List());
    print("recognize3");
    img.Image resizedImage = img.copyResize(oriImage, height: 244, width: 244);
    print("recognize4");

    var results = await Tflite.detectObjectOnBinary(
      binary: imageToByteListUint8(resizedImage, 224),
      numResultsPerClass: 1,
    );
    print("recognize5");
    // final results = await Tflite.runModelOnImage(
    //   path: image.path,
    //   imageMean: 0.0, // defaults to 117.0
    //   imageStd: 256.0, // defaults to 1.0
    //   numResults: 5, // defaults to 5
    //   threshold: 0.01, // defaults to 0.1
    //   asynch: true,
    // );
    // Uint8List byteData = await image.readAsBytes();

    // var results = await Tflite.runModelOnBinary(
    //     binary: byteData, // required
    //     threshold: 0.01, // defaults to 0.1
    //     asynch: true // defaults to true
    //     );
    // var results = await Tflite.runModelOnImage(
    //   path: image.path,
    //   numResults: 6,
    //   threshold: 0.05,
    //   imageMean: 127.5,
    //   imageStd: 127.5,
    // );
    print(results);
    return results
        .map((result) => Inference.fromTfInference(result))
        .where((i) => i != null)
        .toList();
  }

  /// Downloads custom model from the Firebase console and return its file.
  /// located on the mobile device.
  static Future<File> loadModelFromFirebase(String modelName) async {
    try {
      // Create model with a name that is specified in the Firebase console
      final model = FirebaseCustomRemoteModel(modelName);

      // Specify conditions when the model can be downloaded.
      // If there is no wifi access when the app is started,
      // this app will continue loading until the conditions are satisfied.
      final conditions = FirebaseModelDownloadConditions(
          androidRequireWifi: false, iosAllowCellularAccess: true);

      // Create model manager associated with default Firebase App instance.
      final modelManager = FirebaseModelManager.instance;

      // Begin downloading and wait until the model is downloaded successfully.
      await modelManager.download(model, conditions);
      assert(await modelManager.isModelDownloaded(model) == true);

      // Get latest model file to use it for inference by the interpreter.
      var modelFile = await modelManager.getLatestModelFile(model);
      assert(modelFile != null);
      return modelFile;
    } catch (exception) {
      print('Failed on loading your model from Firebase: $exception');
      print('The program will not be resumed');
      rethrow;
    }
  }

  /// Loads the model into some TF Lite interpreter.
  /// In this case interpreter provided by tflite plugin.
  static Future<String> loadTFLiteModel(
      File modelFile, String modelName) async {
    try {
      final appDirectory = await getApplicationDocumentsDirectory();
      // final labelsData = await rootBundle.load("assets/labels_$modelName.txt");
      final labelsData = await rootBundle.load("assets/dict.txt");
      final labelsFile =
          // await File(appDirectory.path + "/_labels_$modelName.txt")
          await File(appDirectory.path + "/_dict.txt").writeAsBytes(labelsData
              .buffer
              .asUint8List(labelsData.offsetInBytes, labelsData.lengthInBytes));
      print("model path: ${modelFile.path}");
      print("label path: ${labelsFile.path}");
      assert(await Tflite.loadModel(
            // model: "assets/model.tflite",
            // labels: "assets/dict.txt",
            // model: "assets/mobilenet_v1_1.0_224.tflite",
            // labels: "assets/labels2.txt",
            model: modelFile.path,
            labels: labelsFile.path,
            isAsset: false,
          ) ==
          "success");
      return "Model is loaded";
    } catch (exception) {
      print(
          'Failed on loading your model to the TFLite interpreter: $exception');
      print('The program will not be resumed');
      rethrow;
    }
  }

  /// downloads the latest model for the given dataset from storage and saves
  /// it in system's temp directory
  Future _downloadModel(Dataset dataset, FirebaseStorage autoMlStorage) async {
    final QuerySnapshot snapshot = await FirebaseFirestore.instance
        .collection("models")
        .where("dataset_id", isEqualTo: dataset.automlId)
        .orderBy("generated_at", descending: true)
        .get();

    // reference to the latest model
    final modelInfo = snapshot.docs.first;
    print("downloading model ${modelInfo['name']}");
    final modelFile = await loadModelFromFirebase(modelInfo['name']);
    await loadTFLiteModel(modelFile, modelInfo['name']);
    return;

    // final filesToDownload = {
    //   modelInfo["model"]: "model.tflite",
    //   modelInfo["label"]: "dict.txt",
    // };

    // final int generatedAt = modelInfo["generated_at"];

    // // create a datasets dir in app's data folder
    // final Directory appDocDir = await getTemporaryDirectory();
    // final Directory modelDir =
    //     Directory("${appDocDir.path}/${dataset.automlId}");
    // print("Using dir ${modelDir.path} for storing models");

    // if (!modelDir.existsSync()) {
    //   modelDir.createSync();
    // }

    // // write a manifest.json for MLKit SDK
    // final File manifestJsonFile = File('${modelDir.path}/manifest.json');
    // if (!manifestJsonFile.existsSync()) {
    //   manifestJsonFile.writeAsString(jsonEncode(MANIFEST_JSON_CONTENTS));
    // }
    // // stores the timestamp at which the latest model was generated
    // final File generatedAtFile = File('${modelDir.path}/generated_at');
    // if (!generatedAtFile.existsSync()) {
    //   generatedAtFile.writeAsStringSync(modelInfo["generated_at"].toString());
    // } else {
    //   // if the timestamp file exists, compare the timestamps to decide if the
    //   // model should be downloaded again.
    //   final storedTimestamp = int.parse(generatedAtFile.readAsStringSync());
    //   if (storedTimestamp >= generatedAt) {
    //     // newer (or same) model is stored, no need to download it again.
    //     print("[DatasetsList] Using cached model");
    //     return Future.value();
    //   }
    // }

    // // TODO: This will be replaced by the ML Kit Model Publishing API when it becomes available.
    // final downloadFutures = filesToDownload.keys.map((filename) async {
    //   final outputFilename = filesToDownload[filename];
    //   print(
    //       "[DatasetsList] Attempting to download $filename at $outputFilename");

    //   final ref = autoMlStorage.ref().child("/$filename");

    //   // store model
    //   final File tempFile = File('${modelDir.path}/$outputFilename');
    //   if (tempFile.existsSync()) {
    //     await tempFile.delete();
    //   }
    //   await tempFile.create();

    //   final StorageFileDownloadTask task = ref.writeToFile(tempFile);

    //   // return bytes downloaded
    //   final int byteCount = (await task.future).totalByteCount;
    //   return DownloadedModelInfo(tempFile.path, byteCount);
    // }).toList();

    // return Future.wait(downloadFutures);
  }
}

class InferenceDialog extends StatelessWidget {
  final File image;
  final List<dynamic> inferences;

  const InferenceDialog(this.image, this.inferences);

  @override
  Widget build(BuildContext context) {
    final labelsList = inferences
        .map((i) => new Text(
              "${i.label.toUpperCase()} ${i.confidence.toStringAsFixed(3)}",
              style: TextStyle(
                fontSize: 16,
              ),
            ))
        .toList();

    return SimpleDialog(
      titlePadding: EdgeInsets.all(0),
      contentPadding: EdgeInsets.all(0),
      children: <Widget>[
        new Container(
          decoration: new BoxDecoration(
            color: Colors.white,
          ),
          child: Image.file(image, fit: BoxFit.fitHeight),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: labelsList.isEmpty
              ? Center(child: Text("No matching labels"))
              : Column(children: labelsList),
        ),
        SimpleDialogOption(
          child: Center(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                    child: FlatButton(
                  onPressed: () {
                    Navigator.pop(context, false);
                  },
                  child: Text(
                    "CLOSE",
                    style: TextStyle(
                      color: Theme.of(context).accentColor,
                    ),
                  ),
                )),
                Expanded(
                  child: RaisedButton(
                    onPressed: () {
                      Navigator.pop(context, true);
                    },
                    color: Theme.of(context).accentColor,
                    elevation: 4.0,
                    child: Text(
                      "RETAKE",
                      style: TextStyle(
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ModelStatusInfo extends StatelessWidget {
  final Dataset dataset;
  final bool doesModelExist;
  final String modelStatus;

  const ModelStatusInfo({this.dataset, this.doesModelExist, this.modelStatus});

  @override
  Widget build(BuildContext context) {
    return new StreamBuilder(
        stream: Firestore.instance
            .collection("operations")
            .where("dataset_id", isEqualTo: dataset.automlId)
            .snapshots(),
        builder: (BuildContext context, AsyncSnapshot<QuerySnapshot> snapshot) {
          if (!snapshot.hasData) return const Text('Loading...');

          var statusText = modelStatus;
          var modelIcon = doesModelExist ? Icons.check : Icons.clear;

          if (snapshot.data.documents.isNotEmpty) {
            final pendingOps = snapshot.data.documents
                .where((document) => document["done"] == false);
            if (pendingOps.length > 0) {
              statusText = "Training under progress";
              modelIcon = Icons.cached;
            }
          }

          return Row(
            children: <Widget>[
              Container(
                decoration: new BoxDecoration(
                  color:
                      doesModelExist ? Color(0x80B2DFDB) : Colors.grey.shade300,
                  borderRadius: new BorderRadius.circular(4.0),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 2.0, horizontal: 4),
                  child: new Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        modelIcon,
                        size: 16,
                        color: doesModelExist ? Colors.teal : Colors.black54,
                      ),
                      SizedBox(width: 4),
                      new Text(
                        statusText,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color:
                                doesModelExist ? Colors.teal : Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        });
  }
}

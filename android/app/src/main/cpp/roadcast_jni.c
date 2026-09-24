#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct roadcast_client roadcast_client_t;

typedef struct {
    uint32_t hz;
    uint32_t frame_count;
    uint32_t signal_count;
    uint32_t schema_version;
    uint64_t schema_hash;
    uint64_t sample_sequence;
    uint64_t change_sequence;
    uint64_t sample_timestamp_ns;
    uint64_t dropped_batches;
    uint64_t coalesced_samples;
    uint64_t resynchronizations;
    uint32_t effective_hz_millihz;
    uint8_t source_state;
    uint8_t connected;
} roadcast_client_status_t;

typedef struct {
    uint64_t raw;
    double physical;
    uint64_t first_observed_ns;
    uint64_t last_change_ns;
    uint8_t state;
    uint8_t calibrated;
} roadcast_signal_value_t;

typedef struct {
    uint64_t stable_id;
    uint32_t index;
    uint32_t invalid_signal_index;
    uint16_t can_id;
    uint8_t kind;
    uint8_t source;
    uint8_t width;
    uint8_t flags;
    double scale;
    double offset;
    char name[64];
    char unit[16];
} roadcast_schema_entry_t;

extern roadcast_client_t *roadcast_client_connect(const char *socket_name,
                                                  int *error);
extern void roadcast_client_close(roadcast_client_t *client);
extern int roadcast_client_status(roadcast_client_t *client,
                                  roadcast_client_status_t *status);
extern const roadcast_schema_entry_t *roadcast_client_schema_at(
        const roadcast_client_t *client, uint32_t index);
extern int32_t roadcast_client_find_signal(const roadcast_client_t *client,
                                           const char *name);
extern int roadcast_client_read_signals(roadcast_client_t *client,
                                        const uint32_t *indices, size_t count,
                                        roadcast_signal_value_t *values);
extern int64_t roadcast_client_sample_age_ns(roadcast_client_t *client);
extern const char *roadcast_client_error_string(int error);

enum {
    ROADCAST_OBSERVATION_VALID = 2,
    ROADCAST_FLAG_VALID = 1,
    ROADCAST_FLAG_CALIBRATED = 2,
    ROADCAST_STATUS_FIELDS = 14,
    ROADCAST_SCHEMA_INTEGER_FIELDS = 8,
    ROADCAST_SCHEMA_DECIMAL_FIELDS = 2,
};

static roadcast_client_t *from_handle(jlong handle) {
    return (roadcast_client_t *)(uintptr_t)handle;
}

JNIEXPORT jlong JNICALL
Java_com_timhss_capyenergy_roadcast_RoadcastNative_nativeConnect(
        JNIEnv *env, jclass clazz, jstring socket_name, jintArray error_out) {
    (void)clazz;
    if (socket_name == NULL) return 0;

    const char *socket = (*env)->GetStringUTFChars(env, socket_name, NULL);
    if (socket == NULL) return 0;

    int error = 0;
    roadcast_client_t *client = roadcast_client_connect(socket, &error);
    (*env)->ReleaseStringUTFChars(env, socket_name, socket);
    if (error_out != NULL && (*env)->GetArrayLength(env, error_out) >= 1) {
        jint value = error;
        (*env)->SetIntArrayRegion(env, error_out, 0, 1, &value);
    }
    return (jlong)(uintptr_t)client;
}

JNIEXPORT void JNICALL
Java_com_timhss_capyenergy_roadcast_RoadcastNative_nativeClose(
        JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    roadcast_client_close(from_handle(handle));
}

JNIEXPORT jint JNICALL
Java_com_timhss_capyenergy_roadcast_RoadcastNative_nativeStatus(
        JNIEnv *env, jclass clazz, jlong handle, jlongArray output) {
    (void)clazz;
    if (handle == 0 || output == NULL ||
        (*env)->GetArrayLength(env, output) < ROADCAST_STATUS_FIELDS) {
        return -1;
    }

    roadcast_client_status_t status;
    int result = roadcast_client_status(from_handle(handle), &status);
    if (result < 0) return result;

    jlong values[ROADCAST_STATUS_FIELDS] = {
            status.hz,
            status.frame_count,
            status.signal_count,
            status.schema_version,
            (jlong)status.schema_hash,
            (jlong)status.sample_sequence,
            (jlong)status.change_sequence,
            (jlong)status.sample_timestamp_ns,
            (jlong)status.dropped_batches,
            (jlong)status.coalesced_samples,
            (jlong)status.resynchronizations,
            status.effective_hz_millihz,
            status.source_state,
            status.connected,
    };
    (*env)->SetLongArrayRegion(env, output, 0, ROADCAST_STATUS_FIELDS, values);
    return result;
}

JNIEXPORT jint JNICALL
Java_com_timhss_capyenergy_roadcast_RoadcastNative_nativeFindSignal(
        JNIEnv *env, jclass clazz, jlong handle, jstring name) {
    (void)clazz;
    if (handle == 0 || name == NULL) return -1;
    const char *native_name = (*env)->GetStringUTFChars(env, name, NULL);
    if (native_name == NULL) return -1;
    int32_t result = roadcast_client_find_signal(from_handle(handle), native_name);
    (*env)->ReleaseStringUTFChars(env, name, native_name);
    return result;
}

JNIEXPORT jobjectArray JNICALL
Java_com_timhss_capyenergy_roadcast_RoadcastNative_nativeSchemaEntry(
        JNIEnv *env, jclass clazz, jlong handle, jint index,
        jlongArray integers, jdoubleArray decimals) {
    (void)clazz;
    if (handle == 0 || index < 0 || integers == NULL || decimals == NULL ||
        (*env)->GetArrayLength(env, integers) < ROADCAST_SCHEMA_INTEGER_FIELDS ||
        (*env)->GetArrayLength(env, decimals) < ROADCAST_SCHEMA_DECIMAL_FIELDS) {
        return NULL;
    }

    const roadcast_schema_entry_t *entry =
            roadcast_client_schema_at(from_handle(handle), (uint32_t)index);
    if (entry == NULL) return NULL;

    jlong integer_values[ROADCAST_SCHEMA_INTEGER_FIELDS] = {
            (jlong)entry->stable_id,
            entry->index,
            entry->invalid_signal_index,
            entry->can_id,
            entry->kind,
            entry->source,
            entry->width,
            entry->flags,
    };
    jdouble decimal_values[ROADCAST_SCHEMA_DECIMAL_FIELDS] = {
            entry->scale,
            entry->offset,
    };
    (*env)->SetLongArrayRegion(
            env, integers, 0, ROADCAST_SCHEMA_INTEGER_FIELDS, integer_values);
    (*env)->SetDoubleArrayRegion(
            env, decimals, 0, ROADCAST_SCHEMA_DECIMAL_FIELDS, decimal_values);

    jclass string_class = (*env)->FindClass(env, "java/lang/String");
    if (string_class == NULL) return NULL;
    jobjectArray strings = (*env)->NewObjectArray(env, 2, string_class, NULL);
    (*env)->DeleteLocalRef(env, string_class);
    if (strings == NULL) return NULL;

    jstring name = (*env)->NewStringUTF(env, entry->name);
    jstring unit = (*env)->NewStringUTF(env, entry->unit);
    if (name == NULL || unit == NULL) {
        if (name != NULL) (*env)->DeleteLocalRef(env, name);
        if (unit != NULL) (*env)->DeleteLocalRef(env, unit);
        (*env)->DeleteLocalRef(env, strings);
        return NULL;
    }
    (*env)->SetObjectArrayElement(env, strings, 0, name);
    (*env)->SetObjectArrayElement(env, strings, 1, unit);
    (*env)->DeleteLocalRef(env, name);
    (*env)->DeleteLocalRef(env, unit);
    return strings;
}

JNIEXPORT jlong JNICALL
Java_com_timhss_capyenergy_roadcast_RoadcastNative_nativeSampleAgeNs(
        JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    if (handle == 0) return -1;
    return roadcast_client_sample_age_ns(from_handle(handle));
}

JNIEXPORT jint JNICALL
Java_com_timhss_capyenergy_roadcast_RoadcastNative_nativeReadSignals(
        JNIEnv *env, jclass clazz, jlong handle, jintArray indices,
        jdoubleArray physical, jlongArray raw, jlongArray last_change_ns,
        jbyteArray flags) {
    (void)clazz;
    if (handle == 0 || indices == NULL || physical == NULL || raw == NULL ||
        last_change_ns == NULL || flags == NULL) {
        return -1;
    }

    jsize count = (*env)->GetArrayLength(env, indices);
    if ((*env)->GetArrayLength(env, physical) < count ||
        (*env)->GetArrayLength(env, raw) < count ||
        (*env)->GetArrayLength(env, last_change_ns) < count ||
        (*env)->GetArrayLength(env, flags) < count) {
        return -1;
    }
    if (count == 0) return 0;

    jint *java_indices = (*env)->GetIntArrayElements(env, indices, NULL);
    uint32_t *native_indices = calloc((size_t)count, sizeof(*native_indices));
    roadcast_signal_value_t *values = calloc((size_t)count, sizeof(*values));
    jdouble *physical_values = calloc((size_t)count, sizeof(*physical_values));
    jlong *raw_values = calloc((size_t)count, sizeof(*raw_values));
    jlong *timestamps = calloc((size_t)count, sizeof(*timestamps));
    jbyte *value_flags = calloc((size_t)count, sizeof(*value_flags));
    if (java_indices == NULL || native_indices == NULL || values == NULL ||
        physical_values == NULL || raw_values == NULL || timestamps == NULL ||
        value_flags == NULL) {
        if (java_indices != NULL) {
            (*env)->ReleaseIntArrayElements(env, indices, java_indices, JNI_ABORT);
        }
        free(native_indices);
        free(values);
        free(physical_values);
        free(raw_values);
        free(timestamps);
        free(value_flags);
        return -7;
    }

    for (jsize i = 0; i < count; ++i) {
        if (java_indices[i] < 0) {
            (*env)->ReleaseIntArrayElements(env, indices, java_indices, JNI_ABORT);
            free(native_indices);
            free(values);
            free(physical_values);
            free(raw_values);
            free(timestamps);
            free(value_flags);
            return -1;
        }
        native_indices[i] = (uint32_t)java_indices[i];
    }
    (*env)->ReleaseIntArrayElements(env, indices, java_indices, JNI_ABORT);

    int result = roadcast_client_read_signals(
            from_handle(handle), native_indices, (size_t)count, values);
    if (result >= 0) {
        for (jsize i = 0; i < count; ++i) {
            physical_values[i] = values[i].physical;
            raw_values[i] = (jlong)values[i].raw;
            timestamps[i] = (jlong)values[i].last_change_ns;
            value_flags[i] =
                    (values[i].state == ROADCAST_OBSERVATION_VALID
                             ? ROADCAST_FLAG_VALID
                             : 0) |
                    (values[i].calibrated ? ROADCAST_FLAG_CALIBRATED : 0);
        }
        (*env)->SetDoubleArrayRegion(env, physical, 0, count, physical_values);
        (*env)->SetLongArrayRegion(env, raw, 0, count, raw_values);
        (*env)->SetLongArrayRegion(env, last_change_ns, 0, count, timestamps);
        (*env)->SetByteArrayRegion(env, flags, 0, count, value_flags);
    }

    free(native_indices);
    free(values);
    free(physical_values);
    free(raw_values);
    free(timestamps);
    free(value_flags);
    return result;
}

JNIEXPORT jstring JNICALL
Java_com_timhss_capyenergy_roadcast_RoadcastNative_nativeErrorString(
        JNIEnv *env, jclass clazz, jint error) {
    (void)clazz;
    const char *message = roadcast_client_error_string(error);
    return (*env)->NewStringUTF(env, message == NULL ? "unknown error" : message);
}

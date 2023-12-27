<template>
  <el-row class="copyright">
    <el-col :span="6" class="copyright-left">
      <a target="_blank" rel="noopener noreferrer" href="https://dev.tekin.cn/">
        &copy;{{ year }} TekinTian
      </a>
    </el-col>
    <el-col :span="18" class="copyright-right">
      <a target="_blank" rel="noopener noreferrer" href="https://api.tekin.cn/motrix/license">
        {{ $t('about.license') }}
      </a>
      <a target="_blank" rel="noopener noreferrer" href="https://api.tekin.cn/motrix/about">
        {{ $t('about.about') }}
      </a>
      <a target="_blank" rel="noopener noreferrer" href="https://api.tekin.cn/motrix/support">
        {{ $t('about.support') }}
      </a>
      <a target="_blank" rel="noopener noreferrer" href="https://api.tekin.cn/motrix/release">
        {{ $t('about.release') }}
      </a>
    </el-col>
  </el-row>
</template>

<script>
  export default {
    name: 'mo-copyright',
    data () {
      const year = new Date().getFullYear()
      return {
        year
      }
    }
  }
</script>

<style lang="scss">
.copyright {
  width: 100%;
  font-size: $--font-size-small;
  a {
    color: $--app-copyright-color;
    text-decoration: none;
  }
}
.copyright-left {
  text-align: left;
}

.copyright-right {
  text-align: right;
  a {
    margin-left: 30px;
  }
}
</style>
